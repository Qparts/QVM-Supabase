// supabase/functions/send_rfq_webhook/index.ts
// Owns the "Send RFQ" action end-to-end: creates the vendor quotations (create_vendors_quotations)
// and fires the n8n webhook that actually notifies vendors, inside one real Postgres transaction
// held open across the webhook call via a raw connection (SUPABASE_DB_URL). If the webhook fails
// (non-2xx or timeout), the transaction is rolled back so the RFQ is never left marked "sent" when
// nothing was actually delivered. Every attempt (success or failure) is logged to
// qvm_new_apps.webhook_logs via the service-role client — a separate connection, so the log survives
// even when the main transaction rolls back.
//
// Payload construction (vendor emails/phones/notification channels, item list) stays client-side
// in SendVendorRFQModal.tsx. The one exception is each vendor's magic-link unique_vendor_url:
// its access_token is generated inside create_vendors_quotations itself, so it can't be known
// client-side until that RPC runs — which now happens here. webhook_payload_base carries
// vendor_list entries keyed by vendor_id/vendor_branch_id instead of a URL; this function fills
// the URL in from the RPC's result right before firing (and logging) the webhook.
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
// fresh on every request (not cached) via the quotation's own client company, using the same
// open transaction connection. Falls back to the RFQ_PO_WEBHOOK_URL secret when that company
// hasn't saved a webhook URL yet (or its company can't be resolved), so existing behavior is
// preserved until an admin configures one.
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

interface VendorListEntryBase {
  vendor_id: number;
  vendor_branch_id: number | null;
  email: string[];
  vendor_name: string;
  phone: string[];
  notification_method: string[];
}

interface WebhookPayloadBase {
  order_number: string;
  date: string;
  type: string;
  car_data: unknown;
  item_list: unknown[];
  vendor_list: VendorListEntryBase[];
}

interface CreatedRow {
  quotation_vendor_id: number;
  vendor_id: number;
  vendor_branch_id: number | null;
  access_token: string;
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
    trigger_type: "send_rfq",
    reference_id: params.referenceId,
    request_url: params.webhookUrl,
    request_payload: params.payload,
    response_status: params.responseStatus,
    response_body: params.responseBody,
    status: params.status,
  });
  if (error) console.error("send_rfq_webhook: failed to write webhook_logs row:", error.message);
}

function vendorKey(vendorId: number, vendorBranchId: number | null): string {
  return `${vendorId}:${vendorBranchId ?? "null"}`;
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
    const { vendor_selections, quotation_id, quotation_items, webhook_payload_base, origin } = body as {
      vendor_selections: unknown;
      quotation_id: number;
      quotation_items: unknown;
      webhook_payload_base: WebhookPayloadBase;
      origin: string;
    };

    if (!quotation_id || !vendor_selections || !quotation_items || !webhook_payload_base) {
      return new Response(
        JSON.stringify({ status: "fail", message: "vendor_selections, quotation_id, quotation_items and webhook_payload_base are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const pool = new Pool(DB_URL, 1, true);
    const conn = await pool.connect();
    try {
      await conn.queryArray("BEGIN");

      let createdRows: CreatedRow[] = [];
      try {
        const r = await conn.queryObject<{ create_vendors_quotations: { status: boolean; message?: string; data?: CreatedRow[] } }>(
          "SELECT public.create_vendors_quotations($1::jsonb, $2::bigint, $3::jsonb) AS create_vendors_quotations",
          [JSON.stringify(vendor_selections), quotation_id, JSON.stringify(quotation_items)]
        );
        const rpcResult = r.rows[0]?.create_vendors_quotations;
        if (!rpcResult?.status) {
          await conn.queryArray("ROLLBACK");
          return new Response(JSON.stringify({ status: "fail", message: rpcResult?.message || "Failed to create vendor quotations" }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        createdRows = Array.isArray(rpcResult.data) ? rpcResult.data : [];
      } catch (rpcErr) {
        await conn.queryArray("ROLLBACK");
        return new Response(JSON.stringify({ status: "fail", message: String(rpcErr) }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const tokenByVendor = new Map<string, string>();
      for (const row of createdRows) {
        const key = vendorKey(row.vendor_id, row.vendor_branch_id);
        if (!tokenByVendor.has(key)) tokenByVendor.set(key, row.access_token);
      }

      const finalPayload = {
        order_number: webhook_payload_base.order_number,
        date: webhook_payload_base.date,
        type: webhook_payload_base.type,
        car_data: webhook_payload_base.car_data,
        item_list: webhook_payload_base.item_list,
        vendor_list: webhook_payload_base.vendor_list.map((v) => {
          const token = tokenByVendor.get(vendorKey(v.vendor_id, v.vendor_branch_id));
          return {
            email: v.email,
            vendor_name: v.vendor_name,
            phone: v.phone,
            notification_method: v.notification_method,
            unique_vendor_url: token ? `${origin}/#/quote-access/${token}` : null,
          };
        }),
      };

      const webhookUrl = await resolveWebhookUrl(conn, quotation_id);

      let webhookStatus: number | null = null;
      let webhookBodyText = "";
      let webhookOk = false;
      try {
        const res = await fetch(webhookUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(finalPayload),
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
        payload: finalPayload,
      });

      if (webhookOk) {
        await conn.queryArray("COMMIT");
        return new Response(JSON.stringify({ status: "success", data: createdRows }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await conn.queryArray("ROLLBACK");
      return new Response(
        JSON.stringify({
          status: "fail",
          message: `Webhook call failed (${webhookStatus ?? "network error"}) — RFQ was not sent, no changes were saved`,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } finally {
      conn.release();
      await pool.end();
    }
  } catch (err) {
    console.error("send_rfq_webhook error:", err);
    return new Response(JSON.stringify({ status: "error", message: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
