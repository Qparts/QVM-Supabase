// supabase/functions/write_item_to_sheet/index.ts
// Adds a new row to the "Spare Part" sheet via AppSheet API
// when a quotation item is inserted.
//
// QNEW-65: every attempt is logged to qvm_new_apps.appsheet_sync_logs - a 'pending' row is
// inserted right before the AppSheet call, then updated with the outcome afterward, via a
// separate service-role client so the log survives regardless of what else happens in the request.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_ID = Deno.env.get("APPSHEET_APP_ID")!;
const ACCESS_KEY = Deno.env.get("APPSHEET_ACCESS_KEY")!;
const TABLE_NAME = Deno.env.get("APPSHEET_TABLE_NAME") ?? "Spare Part";

const APPSHEET_BASE = `https://api.appsheet.com/api/v2/apps/${APP_ID}/tables/${encodeURIComponent(TABLE_NAME)}/Action`;

const logsClient = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
).schema("qvm_new_apps");

async function logSyncStart(action: string, sourceTable: string, recordId: number, payload: unknown, createdBy: string | null) {
  const { data } = await logsClient.from("appsheet_sync_logs")
    .insert({ action, source_table: sourceTable, record_id: recordId, payload_sent: payload, created_by: createdBy })
    .select("id")
    .single();
  return data?.id as number | undefined;
}

async function logSyncFinish(id: number | undefined, status: "success" | "error", response: unknown, httpStatus: number | null, errorMessage?: string) {
  if (!id) return;
  await logsClient.from("appsheet_sync_logs")
    .update({ status, appsheet_response: response, http_status: httpStatus, error_message: errorMessage ?? null, responded_at: new Date().toISOString() })
    .eq("id", id);
}

async function appsheetCall(body: Record<string, unknown>) {
  const res = await fetch(APPSHEET_BASE, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ApplicationAccessKey: ACCESS_KEY,
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  if (!res.ok) {
    throw new Error(`AppSheet ${body.Action} failed: ${res.status} ${JSON.stringify(json)}`);
  }
  return json;
}

// Pulls the HTTP status back out of appsheetCall's "AppSheet Action failed: <status> <body>" error
// message, so failed syncs still populate appsheet_sync_logs.http_status.
function extractHttpStatus(err: unknown): number | null {
  const match = /failed: (\d+)/.exec(String(err));
  return match ? Number(match[1]) : null;
}

serve(async (req) => {
  try {
    const { quotation_item_id, quotation_id, created_by } = await req.json();
    if (!quotation_item_id || !quotation_id) {
      return new Response(JSON.stringify({ error: "quotation_item_id and quotation_id required" }), { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    ).schema("qvm_new_apps");

    // Fetch the quotation item
    const { data: item, error: itemErr } = await supabase
      .from("quotation_items")
      .select("quotation_item_id, part_description, quantity, customer_id, item_status")
      .eq("quotation_item_id", quotation_item_id)
      .maybeSingle();

    if (itemErr || !item) {
      console.error("Item fetch failed:", itemErr);
      return new Response(JSON.stringify({ error: "Item not found" }), { status: 404 });
    }

    // Resolve the item status label from list_data
    let itemStatusName = "";
    if (item.item_status) {
      const { data: statusRow } = await supabase
        .from("list_data")
        .select("list_data")
        .eq("list_data_id", item.item_status)
        .maybeSingle();
      itemStatusName = statusRow?.list_data || "";
    }

    // Fetch the quotation for order_number, plate_number, created_at
    const { data: quotation, error: qErr } = await supabase
      .from("quotations")
      .select("order_number, plate_number, created_at")
      .eq("quotation_id", quotation_id)
      .maybeSingle();

    if (qErr || !quotation) {
      console.error("Quotation fetch failed:", qErr);
      return new Response(JSON.stringify({ error: "Quotation not found" }), { status: 404 });
    }

    // Resolve branch name from customer_id -> client_branches
    let branchName = "";
    if (item.customer_id) {
      const { data: branch } = await supabase
        .from("client_branches")
        .select("branch_name")
        .eq("customer_id", item.customer_id)
        .maybeSingle();
      branchName = branch?.branch_name || "";
    }

    // Fetch the latest note for this item (if any)
    const { data: noteRow } = await supabase
      .from("notes")
      .select("note_description")
      .eq("note_type", "quotation_items")
      .eq("type_id", quotation_item_id)
      .eq("is_deleted", false)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const noteText = noteRow?.note_description || "";

    // Format the order date
    const orderDate = quotation.created_at
      ? new Date(quotation.created_at).toISOString().slice(0, 10)
      : "";

    // Column names must match the actual AppSheet table exactly
    const newRow: Record<string, unknown> = {
      "Job ID": quotation.order_number || "",
      "Quotation_id": String(quotation_id),
      "Quotation_item_ID": String(quotation_item_id),
      "License Plate": quotation.plate_number || "",
      "Part Description": item.part_description || "",
      Quantity: item.quantity ?? 0,
      Estimation: "",
      "Estimation date": "",
      "Insurance Approval": "",
      Order: "",
      Type: "",
      Repair: "",
      "Order Date": orderDate,
      "Delivery Status": itemStatusName,
      "Delivery Date": "",
      Note: noteText,
      "unite price": "",
      "total price": "",
      Branch: branchName,
    };

    const logId = await logSyncStart("add_item", "quotation_items", quotation_item_id, newRow, created_by ?? null);

    try {
      const response = await appsheetCall({
        Action: "Add",
        Properties: {},
        Rows: [newRow],
      });
      await logSyncFinish(logId, "success", response, 200);
    } catch (appsheetErr) {
      await logSyncFinish(logId, "error", null, extractHttpStatus(appsheetErr), String(appsheetErr));
      throw appsheetErr;
    }

    console.log(`Row added for quotation_item_id ${quotation_item_id}`);
    return new Response(JSON.stringify({ success: true, row: newRow }), { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
