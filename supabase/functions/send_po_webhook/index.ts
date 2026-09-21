// supabase/functions/send_po_webhook/index.ts
// Owns the "Send PO" action end-to-end: creates the purchase orders (create_purchase_orders_anditems)
// and fires the n8n webhook that actually notifies vendors, inside one real Postgres transaction
// held open across the webhook call via a raw connection (SUPABASE_DB_URL). If the webhook fails
// (non-2xx or timeout), the transaction is rolled back so no PO is left created when nothing was
// actually delivered to the vendor. Every attempt (success or failure) is logged to
// qvm_new_apps.webhook_logs via the service-role client — a separate connection, so the log survives
// even when the main transaction rolls back.
//
// Payload construction (vendor emails/phones/notification channels, item list, and
// unique_vendor_url built from the vendor's existing quotation_vendors.access_token) stays
// client-side in PricingPage.tsx; this function receives the already-built webhook_payload
// rather than reconstructing it, keeping this change scoped to reliability/observability of the
// webhook call itself. Mirrors send_rfq_webhook/index.ts.
import { Pool } from "https://deno.land/x/postgres@v0.17.0/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const WEBHOOK_TIMEOUT_MS = 15000;

// The webhook target is admin-configurable PER CLIENT COMPANY from the Notification Settings page
// (qvm_new_apps.notification_settings.webhook_base_url, keyed by company_id — the same
// list_data_id space under list_id=1 used by client_branches/get_clients_rows, QNEW-99). Resolved
// fresh on every request via the quotation's own client company, using the same open transaction
// connection. Falls back to the RFQ_PO_WEBHOOK_URL secret when that company hasn't saved a webhook
// URL yet, the purchase order is emailed to the vendors through Gmail instead of falling back to a
// shared webhook. Mirrors send_rfq_webhook/index.ts.
async function resolveWebhookUrl(conn: any, quotationId: number): Promise<string | null> {
  const r = await conn.queryObject<{ webhook_base_url: string | null }>(
    `SELECT ns.webhook_base_url
     FROM qvm_new_apps.quotation_items qi
     JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
     LEFT JOIN qvm_new_apps.notification_settings ns ON ns.company_id = cb.list_data_id
     WHERE qi.quotation_id = $1
     LIMIT 1`,
    [quotationId]
  );
  return r.rows[0]?.webhook_base_url?.trim() || null;
}

// ---------------------------------------------------------------------------- email fallback
//
// No webhook configured for this client company: the purchase order goes to the vendors by email,
// through the Gmail account in the environment — the same sender, and the same rule, as
// send_rfq_webhook. Addresses come from the payload the page built; a vendor the page could not
// find an address for is looked up again here through get_vendor_emails (the vendor's user, its
// admins, its branch users, the vendor's own email), so a thin payload does not sink the order.
const GMAIL_CLIENT_ID = Deno.env.get("GMAIL_CLIENT_ID");
const GMAIL_CLIENT_SECRET = Deno.env.get("GMAIL_CLIENT_SECRET");
const GMAIL_REFRESH_TOKEN = Deno.env.get("GMAIL_REFRESH_TOKEN");
const GMAIL_FROM_EMAIL = Deno.env.get("GMAIL_FROM_EMAIL");

async function gmailAccessToken(): Promise<string> {
  if (!GMAIL_CLIENT_ID || !GMAIL_CLIENT_SECRET || !GMAIL_REFRESH_TOKEN || !GMAIL_FROM_EMAIL) {
    throw new Error(
      "No webhook is configured for this client and the Gmail sender is not set up: " +
      "GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN and GMAIL_FROM_EMAIL are all required."
    );
  }
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: GMAIL_CLIENT_ID,
      client_secret: GMAIL_CLIENT_SECRET,
      refresh_token: GMAIL_REFRESH_TOKEN,
      grant_type: "refresh_token",
    }),
    signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) {
    throw new Error(`Gmail token refresh failed (${res.status}): ${JSON.stringify(body).slice(0, 300)}`);
  }
  return body.access_token as string;
}

/** The vendor's addresses from the database, for a payload entry that carried none. */
async function lookupVendorEmails(conn: any, vendorId: number | null, vendorBranchId: number | null): Promise<string[]> {
  if (!vendorId) return [];
  try {
    const r = await conn.queryObject<{ emails: unknown }>(
      "SELECT qvm_new_apps.get_vendor_emails($1::int[], $2::bigint) AS emails",
      [[vendorId], vendorBranchId],
    );
    const raw = r.rows[0]?.emails;
    const list = Array.isArray(raw) ? raw : (typeof raw === "string" ? JSON.parse(raw) : []);
    return (Array.isArray(list) ? list : []).map((e: unknown) => String(e ?? "").trim()).filter((e: string) => e.includes("@"));
  } catch (e) {
    console.error("send_po_webhook: get_vendor_emails failed:", String(e));
    return [];
  }
}

const esc = (v: unknown) =>
  String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function poEmailHtml(payload: any, vendor: any): string {
  const car = payload?.car_data ?? {};
  const items: any[] = Array.isArray(vendor?.item_list) ? vendor.item_list : [];
  const total = items.reduce(
    (sum, it) => sum + (Number(it?.cost) || 0) * (Number(it?.qty) || 0),
    0,
  );
  const rows = items
    .map(
      (it) => `<tr>
        <td style="padding:8px 10px;border-bottom:1px solid #e2e8f0;font-family:monospace">${esc(it.vendor_part_number || it.part_number)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #e2e8f0">${esc(it.part_description)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:center">${esc(it.qty)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:right">${(Number(it.cost) || 0).toFixed(2)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:right">${((Number(it.cost) || 0) * (Number(it.qty) || 0)).toFixed(2)}</td>
      </tr>`,
    )
    .join("");

  const vehicle = [car.make, car.model, car.plate_number && `(${car.plate_number})`].filter(Boolean).join(" ");

  return `<div style="font-family:Segoe UI,Arial,sans-serif;color:#0f172a;max-width:720px">
    <h2 style="margin:0 0 4px">Purchase Order ${esc(payload?.order_number)}</h2>
    <p style="margin:0 0 16px;color:#64748b;font-size:13px">
      ${esc(vendor?.vendor_name)} &middot; ${esc(payload?.date)}${vehicle ? ` &middot; ${esc(vehicle)}` : ""}
      ${car.vin ? `<br>VIN: <span style="font-family:monospace">${esc(car.vin)}</span>` : ""}
    </p>
    <table style="border-collapse:collapse;width:100%;font-size:13px">
      <thead>
        <tr style="background:#f8fafc;text-align:left;color:#475569">
          <th style="padding:8px 10px">Part #</th>
          <th style="padding:8px 10px">Description</th>
          <th style="padding:8px 10px;text-align:center">Qty</th>
          <th style="padding:8px 10px;text-align:right">Unit</th>
          <th style="padding:8px 10px;text-align:right">Total</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
      <tfoot>
        <tr>
          <td colspan="4" style="padding:10px;text-align:right;font-weight:bold">Total</td>
          <td style="padding:10px;text-align:right;font-weight:bold">${total.toFixed(2)} SAR</td>
        </tr>
      </tfoot>
    </table>
    ${vendor?.unique_vendor_url ? `<p style="margin:16px 0 0"><a href="${esc(vendor.unique_vendor_url)}">Open the order</a></p>` : ""}
  </div>`;
}

async function emailVendors(payload: any, conn: any, poItems: any[]): Promise<{ sent: number; failed: number; unreachable: string[]; detail: string[] }> {
  const vendors: any[] = Array.isArray(payload?.vendor_list) ? payload.vendor_list : [];
  const detail: string[] = [];
  const unreachable: string[] = [];
  let sent = 0;
  let failed = 0;
  if (vendors.length === 0) return { sent, failed, unreachable, detail: ["the payload names no vendor"] };

  const token = await gmailAccessToken();

  // The vendors on the order, by id, for entries the page did not stamp with one.
  const poVendorIds = Array.from(new Set(poItems.map((it) => Number(it?.vendor_id)).filter((n) => n > 0)));
  let namesById = new Map<number, string>();
  if (poVendorIds.length) {
    try {
      const r = await conn.queryObject<{ vendor_id: number; vendor_name: string }>(
        "SELECT vendor_id, vendor_name FROM qvm_new_apps.vendors WHERE vendor_id = ANY($1::int[])", [poVendorIds]);
      namesById = new Map(r.rows.map((row) => [Number(row.vendor_id), String(row.vendor_name ?? "")]));
    } catch { /* the name match is a convenience; a stamped vendor_id needs none */ }
  }

  for (const v of vendors) {
    let to = (Array.isArray(v?.email) ? v.email : [v?.email])
      .map((e: unknown) => String(e ?? "").trim())
      .filter((e: string) => e.includes("@"));
    if (to.length === 0) {
      const vendorId = Number(v?.vendor_id) ||
        (Array.from(namesById.entries()).find(([, name]) => name === String(v?.vendor_name ?? ""))?.[0] ?? null);
      const branchId = v?.vendor_branch_id != null ? Number(v.vendor_branch_id)
        : (poItems.find((it) => Number(it?.vendor_id) === vendorId)?.vendor_branch_id ?? null);
      to = await lookupVendorEmails(conn, vendorId, branchId == null ? null : Number(branchId));
    }
    if (to.length === 0) {
      // Nothing to deliver to is not a delivery failure: the order is saved and the caller is told.
      unreachable.push(String(v?.vendor_name ?? "vendor"));
      detail.push(`${v?.vendor_name ?? "vendor"}: no email address on file for the vendor or any of its users`);
      continue;
    }

    const raw =
      `From: ${GMAIL_FROM_EMAIL}\r\n` +
      `To: ${to.join(", ")}\r\n` +
      `Subject: =?UTF-8?B?${btoa(unescape(encodeURIComponent(`Purchase Order ${payload?.order_number ?? ""}`)))}?=\r\n` +
      `MIME-Version: 1.0\r\n` +
      `Content-Type: text/html; charset=UTF-8\r\n\r\n` +
      poEmailHtml(payload, v);
    const encoded = btoa(unescape(encodeURIComponent(raw)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

    try {
      const res = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ raw: encoded }),
        signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
      });
      if (res.ok) {
        sent += 1;
        detail.push(`${v?.vendor_name ?? "vendor"}: sent to ${to.join(", ")}`);
      } else {
        failed += 1;
        detail.push(`${v?.vendor_name ?? "vendor"}: gmail ${res.status} ${(await res.text()).slice(0, 200)}`);
      }
    } catch (mailErr) {
      failed += 1;
      detail.push(`${v?.vendor_name ?? "vendor"}: ${String(mailErr)}`);
    }
  }

  return { sent, failed, unreachable, detail };
}

async function logAttempt(params: {
  referenceId: number;
  webhookUrl: string;
  status: "success" | "failed";
  responseStatus: number | null;
  responseBody: string;
  payload: unknown;
}) {
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await supabase.schema("qvm_new_apps").from("webhook_logs").insert({
    trigger_type: "send_po",
    reference_id: params.referenceId,
    request_url: params.webhookUrl,
    request_payload: params.payload,
    response_status: params.responseStatus,
    response_body: params.responseBody,
    status: params.status,
  });
  if (error) console.error("send_po_webhook: failed to write webhook_logs row:", error.message);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ status: "fail", message: "Not authorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // The DB work below runs on a raw pool connection, which carries no JWT — so auth.uid() was
    // NULL for the whole transaction and purchase_orders.created_by came out empty on every PO
    // sent this way. Resolve the caller here and replay their identity onto the connection.
    // Verified through the auth server rather than decoded locally: the header was previously only
    // checked for existence, so any non-empty value got in.
    const token = authHeader.replace(/^Bearer\s+/i, "");
    const { data: authData, error: authError } = await createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    ).auth.getUser(token);

    if (authError || !authData?.user?.id) {
      return new Response(JSON.stringify({ status: "fail", message: "Not authorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const actingUserId = authData.user.id;

    const body = await req.json();
    const { po_items, quotation_id, webhook_payload } = body as {
      po_items: unknown;
      quotation_id: number;
      webhook_payload: unknown;
    };

    if (!quotation_id || !po_items || !webhook_payload) {
      return new Response(
        JSON.stringify({ status: "fail", message: "po_items, quotation_id and webhook_payload are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const pool = new Pool(DB_URL, 1, true);
    const conn = await pool.connect();
    try {
      await conn.queryArray("BEGIN");

      // Scoped to this transaction (set_config local = true), so auth.uid() resolves for the RPC
      // and for every trigger it fires — created_by/updated_by, status_logs.status_changed_by.
      await conn.queryArray("SELECT set_config('request.jwt.claims', $1, true)", [
        JSON.stringify({ sub: actingUserId, role: "authenticated" }),
      ]);

      let rpcResult: unknown;
      try {
        const r = await conn.queryObject<{ create_purchase_orders_anditems: unknown }>(
          "SELECT qvm_new_apps.create_purchase_orders_anditems($1::jsonb) AS create_purchase_orders_anditems",
          [JSON.stringify(po_items)]
        );
        rpcResult = r.rows[0]?.create_purchase_orders_anditems;
      } catch (rpcErr) {
        await conn.queryArray("ROLLBACK");
        return new Response(JSON.stringify({ status: "fail", message: String(rpcErr) }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const webhookUrl = await resolveWebhookUrl(conn, quotation_id);

      // No webhook saved for this client: email the vendors their purchase order instead. Same
      // all-or-nothing rule as the webhook path — if not one vendor could be reached, the purchase
      // orders are rolled back rather than left created against a notification nobody received.
      if (!webhookUrl) {
        let sent = 0;
        let failed = 0;
        let unreachable: string[] = [];
        let detail: string[] = [];
        let emailError = "";
        try {
          ({ sent, failed, unreachable, detail } = await emailVendors(webhook_payload, conn, Array.isArray(po_items) ? po_items as any[] : []));
        } catch (mailErr) {
          emailError = String(mailErr);
        }

        await logAttempt({
          referenceId: quotation_id,
          webhookUrl: "gmail://" + (GMAIL_FROM_EMAIL ?? "unconfigured"),
          status: sent > 0 ? "success" : "failed",
          responseStatus: null,
          responseBody: emailError || `sent ${sent}, failed ${failed}\n${detail.join("\n")}`,
          payload: webhook_payload,
        });

        // Saved when at least one vendor was emailed, and also when nobody could be emailed only
        // because no vendor has an address on file: there was nothing to deliver, not a failed
        // delivery, and a vendor reached by phone still needs their purchase order to exist.
        // Rolled back when a send was attempted and every one failed, or the sender itself is broken.
        const nothingToDeliver = !emailError && sent === 0 && failed === 0 && unreachable.length > 0;
        if (sent > 0 || nothingToDeliver) {
          await conn.queryArray("COMMIT");
          return new Response(
            JSON.stringify({
              status: "success", delivery: sent > 0 ? "email" : "none", emailed: sent, failed, unreachable, detail, data: rpcResult,
              warning: unreachable.length
                ? `Saved, but no purchase order email went to ${unreachable.join(", ")}: no email address on file for the vendor or any of its users. Notify them yourself, or add an email on the vendor's profile.`
                : null,
            }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        await conn.queryArray("ROLLBACK");
        return new Response(
          JSON.stringify({
            status: "fail",
            delivery: "email",
            message: emailError
              || `No webhook is configured for this client and the purchase order could not be emailed to any vendor — nothing was saved. ${detail.join("; ")}`,
          }),
          { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      let webhookStatus: number | null = null;
      let webhookBodyText = "";
      let webhookOk = false;
      try {
        const res = await fetch(webhookUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(webhook_payload),
          signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
        });
        webhookStatus = res.status;
        webhookBodyText = await res.text();
        webhookOk = res.ok;
      } catch (fetchErr) {
        webhookBodyText = String(fetchErr);
      }

      await logAttempt({
        referenceId: quotation_id,
        webhookUrl,
        status: webhookOk ? "success" : "failed",
        responseStatus: webhookStatus,
        responseBody: webhookBodyText,
        payload: webhook_payload,
      });

      if (webhookOk) {
        await conn.queryArray("COMMIT");
        return new Response(JSON.stringify({ status: "success", data: rpcResult }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await conn.queryArray("ROLLBACK");
      return new Response(
        JSON.stringify({
          status: "fail",
          message: `Webhook call failed (${webhookStatus ?? "network error"}) — Purchase Order was not created, no changes were saved`,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } finally {
      conn.release();
      await pool.end();
    }
  } catch (err) {
    console.error("send_po_webhook error:", err);
    return new Response(JSON.stringify({ status: "error", message: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
