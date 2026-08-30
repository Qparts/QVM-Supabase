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
// URL yet (or its company can't be resolved). Mirrors send_rfq_webhook/index.ts.
async function resolveWebhookUrl(conn: any, quotationId: number): Promise<string> {
  const r = await conn.queryObject<{ webhook_base_url: string | null }>(
    `SELECT ns.webhook_base_url
     FROM qvm_new_apps.quotation_items qi
     JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
     LEFT JOIN qvm_new_apps.notification_settings ns ON ns.company_id = cb.list_data_id
     WHERE qi.quotation_id = $1
     LIMIT 1`,
    [quotationId]
  );
  return r.rows[0]?.webhook_base_url || Deno.env.get("RFQ_PO_WEBHOOK_URL")!;
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
