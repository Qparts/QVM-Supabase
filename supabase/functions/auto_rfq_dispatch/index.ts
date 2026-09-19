// supabase/functions/auto_rfq_dispatch/index.ts
//
// Sends the RFQs the auto-RFQ rules queued for one order. Woken by the database trigger through
// pg_net (with the shared secret from Vault) the moment a matching line reaches its status; also
// callable by a Qparts Admin from the settings page to retry.
//
// It waits a short while first — an order created with eight lines fires the trigger eight times,
// and the vendor should get one RFQ — then CLAIMS the queued rows atomically (auto_rfq_claim flips
// queued → sending), so two overlapping wake-ups can never both send the same row. Vendors that
// matched the same set of lines are grouped into one call to send_rfq_webhook: the same function,
// payload, per-company webhook / Gmail fallback and webhook_logs row as a manual send, so the vendor
// cannot tell the two apart and neither can the log.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-auto-rfq-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VENDOR_ITEM_STATUS_SENT = 157;

type Claimed = { send_id: number; rule_id: number | null; quotation_item_id: number; vendor_id: number; vendor_branch_id: number | null; trigger_status: number };
type Payload = {
  order: { quotation_id: number; order_number: string; plate_number: string | null; created_at: string } | null;
  car: { vin: string | null; make: string | null; model: string | null; year: number | null } | null;
  items: Array<{ quotation_item_id: number; part_number: string | null; part_description: string | null; class: string | null; qty: number | null }>;
  settings: Record<string, string | null> | null;
  vendors: Array<{ vendor_id: number; vendor_name: string | null; email: string | null; phone_numbers: unknown; branches: Array<{ vendor_branch_id: number; phone: string | null }> }>;
};

const vendorKey = (vendorId: number, branchId: number | null) => `${vendorId}:${branchId ?? "none"}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const db = admin.schema("qvm_new_apps");

  try {
    const body = (await req.json().catch(() => ({}))) as { quotation_id?: number; immediate?: boolean };
    const quotationId = Number(body.quotation_id);
    if (!quotationId) return json({ status: "fail", message: "quotation_id is required" }, 400);

    // Who is calling: the trigger, with the shared secret — or a Qparts Admin, with their session.
    const secret = req.headers.get("x-auto-rfq-secret");
    let allowed = false;
    if (secret) {
      const { data } = await db.rpc("auto_rfq_secret_ok", { p_secret: secret });
      allowed = data === true;
    }
    if (!allowed) {
      const auth = req.headers.get("Authorization") || "";
      if (auth.startsWith("Bearer ")) {
        const { data: u } = await admin.auth.getUser(auth.slice(7));
        if (u?.user) {
          // A Qparts Admin: internal user type with the admin role — read directly, since the SQL
          // gate keys on auth.uid(), which is nobody on a service-role connection.
          const { data: row } = await db.from("user_data").select("user_type, user_role").eq("user_id", u.user.id).maybeSingle();
          allowed = Number(row?.user_type) === 185 && Number(row?.user_role) === 172;
        }
      }
    }
    if (!allowed) return json({ status: "fail", message: "Not authorized" }, 401);

    // Let the rest of the order's lines arrive before sending one RFQ for all of them.
    if (!body.immediate) {
      const { data: s } = await db.from("auto_rfq_settings").select("value").eq("key", "debounce_seconds").maybeSingle();
      const wait = Math.min(Math.max(Number(s?.value ?? 20) || 20, 0), 90);
      await new Promise((r) => setTimeout(r, wait * 1000));
    }

    const { data: claimedRaw, error: claimErr } = await db.rpc("auto_rfq_claim", { p_quotation_id: quotationId });
    if (claimErr) return json({ status: "fail", message: claimErr.message }, 500);
    const claimed = (claimedRaw ?? []) as Claimed[];
    if (claimed.length === 0) return json({ status: "success", claimed: 0, message: "Nothing queued for this order" });

    const { data: payloadRaw, error: payloadErr } = await db.rpc("auto_rfq_payload", { p_quotation_id: quotationId });
    if (payloadErr || !payloadRaw?.order) {
      await db.rpc("auto_rfq_mark", { p_send_ids: claimed.map((c) => c.send_id), p_status: "failed", p_error: payloadErr?.message || "Order not found" });
      return json({ status: "fail", message: payloadErr?.message || "Order not found" }, 500);
    }
    const payload = payloadRaw as Payload;
    const origin = (payload.settings?.app_origin || "").trim();

    // Vendors sharing the same set of lines go in one send: create_vendors_quotations applies the
    // item list to every vendor in a selection, so vendors with different lines need separate calls.
    const byVendor = new Map<string, { vendor_id: number; vendor_branch_id: number | null; rows: Claimed[] }>();
    for (const c of claimed) {
      const k = vendorKey(c.vendor_id, c.vendor_branch_id);
      const g = byVendor.get(k) ?? { vendor_id: c.vendor_id, vendor_branch_id: c.vendor_branch_id, rows: [] };
      g.rows.push(c);
      byVendor.set(k, g);
    }
    const groups = new Map<string, Array<{ vendor_id: number; vendor_branch_id: number | null; rows: Claimed[] }>>();
    for (const g of byVendor.values()) {
      const key = Array.from(new Set(g.rows.map((r) => r.quotation_item_id))).sort((a, b) => a - b).join(",");
      groups.set(key, [...(groups.get(key) ?? []), g]);
    }

    const results: unknown[] = [];
    for (const [itemKey, vendorGroups] of groups) {
      const itemIds = itemKey.split(",").map(Number);
      const sendIds = vendorGroups.flatMap((g) => g.rows.map((r) => r.send_id));

      const vendorList = await Promise.all(vendorGroups.map(async (g) => {
        const v = payload.vendors.find((x) => x.vendor_id === g.vendor_id);
        let emails: string[] = [];
        try {
          const { data } = await db.rpc("get_vendor_emails", { p_vendor_ids: [g.vendor_id], p_vendor_branch_id: g.vendor_branch_id });
          emails = Array.isArray(data) ? (data as string[]).map((e) => String(e).trim()).filter(Boolean) : [];
        } catch { /* fall back to the vendor's own address */ }
        if (emails.length === 0 && v?.email) emails = [String(v.email).trim()];
        let phone: string[] = [];
        const branchPhone = g.vendor_branch_id ? v?.branches.find((b) => b.vendor_branch_id === g.vendor_branch_id)?.phone : null;
        if (branchPhone) phone = [String(branchPhone).trim()];
        else if (Array.isArray(v?.phone_numbers)) phone = (v!.phone_numbers as unknown[]).map((p) => String(p).trim()).filter(Boolean);
        let notification_method: string[] = ["email"];
        try {
          const { data } = await db.rpc("get_vendor_branch_notification_methods", { p_vendor_id: g.vendor_id, p_vendor_branch_id: g.vendor_branch_id });
          if (Array.isArray(data) && data.length) notification_method = data as string[];
        } catch { /* email is the default */ }
        return { vendor_id: g.vendor_id, vendor_branch_id: g.vendor_branch_id, email: emails, vendor_name: v?.vendor_name || "", phone, notification_method };
      }));

      const requestBody = {
        vendor_selections: vendorGroups.map((g) => ({ vendor_id: g.vendor_id, vendor_branch_id: g.vendor_branch_id })),
        quotation_id: quotationId,
        quotation_items: itemIds.map((id) => ({ quotation_item_id: id, cost: 0, vendor_item_status: VENDOR_ITEM_STATUS_SENT })),
        webhook_payload_base: {
          order_number: payload.order!.order_number,
          date: String(payload.order!.created_at || "").slice(0, 10) || new Date().toISOString().slice(0, 10),
          type: "RFQ",
          car_data: {
            vin: payload.car?.vin || "",
            make: payload.car?.make || "",
            model: payload.car?.model || "",
            year: payload.car?.year ? Number(payload.car.year) || 0 : 0,
            plate_number: payload.order!.plate_number || "",
          },
          item_list: payload.items.filter((it) => itemIds.includes(it.quotation_item_id)).map((it) => ({
            part_number: it.part_number, part_description: it.part_description, class: it.class || "", qty: it.qty,
          })),
          vendor_list: vendorList,
        },
        origin,
      };

      let ok = false; let message = "";
      let created: Array<{ quotation_vendor_id: number }> = [];
      try {
        const res = await fetch(`${SUPABASE_URL}/functions/v1/send_rfq_webhook`, {
          method: "POST",
          headers: { "Content-Type": "application/json", apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
          body: JSON.stringify(requestBody),
        });
        const out = await res.json().catch(() => ({}));
        ok = res.ok && String(out?.status || "").toLowerCase() === "success";
        message = String(out?.message || (ok ? "" : `HTTP ${res.status}`));
        created = Array.isArray(out?.data) ? out.data : [];
      } catch (e) {
        message = String(e);
      }

      // The webhook_logs row the send wrote, for the record.
      const { data: log } = await db.from("webhook_logs").select("id").eq("trigger_type", "send_rfq").eq("reference_id", quotationId)
        .order("id", { ascending: false }).limit(1).maybeSingle();

      await db.rpc("auto_rfq_mark", { p_send_ids: sendIds, p_status: ok ? "sent" : "failed", p_error: ok ? null : message, p_webhook_log_id: log?.id ?? null });
      if (ok) {
        for (const qv of Array.from(new Set(created.map((r) => r.quotation_vendor_id))).filter(Boolean)) {
          try { await db.rpc("update_vendor_status", { p_quotation_vendor_id: qv }); } catch { /* aggregate only */ }
        }
      }
      results.push({ items: itemIds, vendors: vendorGroups.length, ok, message });
    }

    return json({ status: "success", claimed: claimed.length, sends: results });
  } catch (e) {
    return json({ status: "fail", message: (e as Error).message || "Unexpected error" }, 500);
  }
});
