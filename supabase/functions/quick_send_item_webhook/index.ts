// supabase/functions/quick_send_item_webhook/index.ts
// QNEW-67 "Quick Send to Vendor": for a SINGLE item added after the initial RFQ send, create its
// quotation_vendor_items rows for every vendor already on the quotation (additively, via
// quick_send_item_to_vendors -- unlike create_vendors_quotations it never wipes a vendor's other
// items), then notify those vendors through the SAME n8n webhook the initial RFQ send uses
// (email/WhatsApp per each vendor's notification channels). The item is created/unlocked regardless
// of whether the notification webhook succeeds (best-effort); every attempt is logged to webhook_logs.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const WEBHOOK_URL = Deno.env.get("RFQ_PO_WEBHOOK_URL")!;
const WEBHOOK_TIMEOUT_MS = 15000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ status: "fail", message: "Not authorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { quotation_item_id, origin } = body as { quotation_item_id: number; origin?: string };
    if (!quotation_item_id) {
      return new Response(JSON.stringify({ status: "fail", message: "quotation_item_id is required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // User-scoped client so auth.uid() inside the RPC resolves to the calling admin (created_by / status log).
    const userClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authHeader } } });
    const svc = createClient(SUPABASE_URL, SERVICE);

    // 1) Additive create + mark sent + log; returns vendors (with tokens) + car/item/order data.
    const { data: rpcData, error: rpcErr } = await userClient
      .schema("qvm_new_apps")
      .rpc("quick_send_item_to_vendors", { p_quotation_item_id: quotation_item_id });
    if (rpcErr) {
      return new Response(JSON.stringify({ status: "fail", message: rpcErr.message }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!rpcData || rpcData.status !== true) {
      return new Response(JSON.stringify({ status: "fail", message: rpcData?.message || "Failed to quick-send item" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const created: Array<{ vendor_id: number; vendor_branch_id: number | null; access_token: string }> =
      Array.isArray(rpcData.created) ? rpcData.created : [];
    const baseOrigin = (origin && String(origin).trim()) || "https://qparts.store";

    // 2) Build the vendor_list (email / phone / channels) — same shape the initial RFQ webhook uses.
    const vendor_list = [];
    for (const v of created) {
      let email = "";
      try {
        const { data: em } = await svc.schema("qvm_new_apps").rpc("get_vendor_emails", {
          p_vendor_ids: [v.vendor_id], p_vendor_branch_id: v.vendor_branch_id,
        });
        if (Array.isArray(em) && em.length) email = String(em[0]).trim();
      } catch (_) { /* ignore */ }

      let phone: string[] = [];
      try {
        if (v.vendor_branch_id) {
          const { data: b } = await svc.schema("qvm_new_apps").from("vendor_branches")
            .select("phone").eq("vendor_branch_id", v.vendor_branch_id).maybeSingle();
          if (b?.phone) phone = [String(b.phone).trim()];
        }
        if (phone.length === 0) {
          const { data: vr } = await svc.schema("qvm_new_apps").from("vendors")
            .select("phone_numbers").eq("vendor_id", v.vendor_id).maybeSingle();
          const raw = vr?.phone_numbers as unknown;
          if (Array.isArray(raw)) phone = raw.map((p) => String(p).trim()).filter(Boolean);
          else if (raw != null && String(raw).trim()) phone = [String(raw).trim()];
        }
      } catch (_) { /* ignore */ }

      let notification_method: string[] = ["email"];
      try {
        const { data: ch } = await svc.schema("qvm_new_apps").rpc("get_vendor_notification_channels", { p_vendor_id: v.vendor_id });
        const arr = (Array.isArray(ch) ? ch : []).filter((m: string) => m === "email" || m === "whatsapp");
        if (arr.length) notification_method = arr;
      } catch (_) { /* ignore */ }

      let vendor_name = "";
      try {
        const { data: vn } = await svc.schema("qvm_new_apps").from("vendors")
          .select("vendor_name").eq("vendor_id", v.vendor_id).maybeSingle();
        vendor_name = vn?.vendor_name ? String(vn.vendor_name) : "";
      } catch (_) { /* ignore */ }

      vendor_list.push({
        email, vendor_name, phone, notification_method,
        unique_vendor_url: v.access_token ? `${baseOrigin}/#/quote-access/${v.access_token}` : null,
      });
    }

    const finalPayload = {
      order_number: rpcData.order_number,
      date: rpcData.date,
      type: "RFQ",
      car_data: rpcData.car_data,
      item_list: rpcData.item_list,
      vendor_list,
    };

    // 3) Fire the same n8n notification webhook (best-effort — the item is already created & editable).
    let webhookStatus: number | null = null;
    let webhookBody = "";
    let webhookOk = false;
    try {
      const res = await fetch(WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(finalPayload),
        signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
      });
      webhookStatus = res.status;
      webhookBody = await res.text();
      webhookOk = res.ok;
    } catch (fetchErr) {
      webhookBody = String(fetchErr);
    }

    // 4) Log the attempt (mirrors send_rfq_webhook).
    try {
      await svc.schema("qvm_new_apps").from("webhook_logs").insert({
        trigger_type: "send_rfq",
        reference_id: rpcData.quotation_id,
        request_url: WEBHOOK_URL,
        request_payload: finalPayload,
        response_status: webhookStatus,
        response_body: webhookBody,
        status: webhookOk ? "success" : "failed",
      });
    } catch (_) { /* logging is best-effort */ }

    return new Response(
      JSON.stringify({ status: "success", created_count: rpcData.created_count, notified: webhookOk }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("quick_send_item_webhook error:", err);
    return new Response(JSON.stringify({ status: "error", message: String(err) }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
