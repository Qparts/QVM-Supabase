// supabase/functions/bulk_update_items_in_sheet/index.ts
// Takes a chunk of quotation_item_ids and syncs their current DB values into the
// "Spare Part" AppSheet table (same sheet write_item_to_sheet / update_item_status_in_sheet /
// update_item_description_in_sheet / write_price_to_sheet already write to). The whole chunk is
// synced in at most 3 AppSheet API calls total (one Find, one Edit, one Add) instead of one call
// per item.
//
// Rows are matched to sheet rows via "quotation_item_id" (lowercase field name in AppSheet's
// underlying data, though its Filter() column reference is case-insensitive). Existing rows get
// their Delivery Status, part_number, Part Description, Note and unite price refreshed. Items
// with no matching row are added as new rows (same shape write_item_to_sheet creates), stamped
// with the same 5 fields plus the identifying/context columns (Job ID, License Plate, Quantity,
// Order Date, Branch).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_ID = Deno.env.get("APPSHEET_APP_ID")!;
const ACCESS_KEY = Deno.env.get("APPSHEET_ACCESS_KEY")!;
const TABLE_NAME = Deno.env.get("APPSHEET_TABLE_NAME") ?? "Spare Part";

const APPSHEET_BASE = `https://api.appsheet.com/api/v2/apps/${APP_ID}/tables/${encodeURIComponent(TABLE_NAME)}/Action`;

const MAX_IDS_PER_REQUEST = 300;

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

// Finds sheet rows for the whole chunk of quotation_item_ids in a single call; returns a map of
// quotation_item_id (as string) -> AppSheet row key ("ID"), plus the raw selector/response
// (for debug=true diagnostics).
async function findRowIds(
  ids: (string | number)[]
): Promise<{ map: Map<string, string>; selector: string; result: unknown }> {
  const list = ids.map((id) => `"${String(id).replace(/"/g, '\\"')}"`).join(",");
  const selector = `Filter("${TABLE_NAME}", IN([quotation_item_id], LIST(${list})))`;
  const result = await appsheetCall({
    Action: "Find",
    Properties: { Selector: selector },
    Rows: [],
  });
  const map = new Map<string, string>();
  if (Array.isArray(result)) {
    for (const row of result) {
      const key = row?.["quotation_item_id"];
      const id = row?.["ID"];
      if (key != null && id != null) map.set(String(key), String(id));
    }
  }
  return { map, selector, result };
}

serve(async (req) => {
  try {
    const { quotation_item_ids, debug } = await req.json();
    if (!Array.isArray(quotation_item_ids) || quotation_item_ids.length === 0) {
      return new Response(JSON.stringify({ error: "quotation_item_ids required" }), { status: 400 });
    }
    if (quotation_item_ids.length > MAX_IDS_PER_REQUEST) {
      return new Response(
        JSON.stringify({ error: `Too many ids in one request (max ${MAX_IDS_PER_REQUEST}); split into smaller chunks` }),
        { status: 400 }
      );
    }
    const ids = [...new Set(quotation_item_ids.map((n: unknown) => Number(n)).filter((n) => Number.isInteger(n) && n > 0))];
    if (ids.length === 0) {
      return new Response(JSON.stringify({ error: "No valid quotation_item_ids provided" }), { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    ).schema("qvm_new_apps");

    const { data: items, error: itemsErr } = await supabase
      .from("quotation_items")
      .select("quotation_item_id, quotation_id, part_number, part_description, quantity, item_status, price_before_vat, customer_id")
      .in("quotation_item_id", ids);
    if (itemsErr) throw itemsErr;

    const foundIds = new Set((items ?? []).map((i) => i.quotation_item_id));
    const missing = ids.filter((id) => !foundIds.has(id));

    const statusIds = [...new Set((items ?? []).map((i) => i.item_status).filter((v) => v != null))];
    const quotationIds = [...new Set((items ?? []).map((i) => i.quotation_id).filter((v) => v != null))];
    const customerIds = [...new Set((items ?? []).map((i) => i.customer_id).filter((v) => v != null))];

    const [{ data: statusRows }, { data: quotationRows }, { data: branchRows }, { data: noteRows }] = await Promise.all([
      statusIds.length
        ? supabase.from("list_data").select("list_data_id, list_data").in("list_data_id", statusIds)
        : Promise.resolve({ data: [] as any[] }),
      quotationIds.length
        ? supabase.from("quotations").select("quotation_id, order_number, plate_number, created_at").in("quotation_id", quotationIds)
        : Promise.resolve({ data: [] as any[] }),
      customerIds.length
        ? supabase.from("client_branches").select("customer_id, branch_name").in("customer_id", customerIds)
        : Promise.resolve({ data: [] as any[] }),
      supabase
        .from("notes")
        .select("type_id, note_description, created_at")
        .eq("note_type", "quotation_items")
        .eq("is_deleted", false)
        .in("type_id", ids)
        .order("created_at", { ascending: false }),
    ]);

    const statusById = new Map((statusRows ?? []).map((s: any) => [s.list_data_id, s.list_data]));
    const quotationById = new Map((quotationRows ?? []).map((q: any) => [q.quotation_id, q]));
    const branchByCustomer = new Map((branchRows ?? []).map((b: any) => [b.customer_id, b.branch_name]));
    const latestNoteByItem = new Map<number, string>();
    for (const n of noteRows ?? []) {
      if (!latestNoteByItem.has(n.type_id)) latestNoteByItem.set(n.type_id, n.note_description || "");
    }

    // The 5 fields kept in sync on every existing row, matching the single-item update
    // functions (status, part_number, price, part_description, note).
    const syncFields = (item: any) => {
      const fields: Record<string, unknown> = {
        "Delivery Status": statusById.get(item.item_status) || "",
        "part_number": item.part_number || "",
        "Part Description": item.part_description || "",
        "Note": latestNoteByItem.get(item.quotation_item_id) || "",
      };
      if (item.price_before_vat != null) fields["unite price"] = item.price_before_vat;
      return fields;
    };

    const { map: rowIdMap, selector, result: findResult } = await findRowIds(ids);
    if (debug) {
      return new Response(JSON.stringify({ ids, selector, findResult }, null, 2), { status: 200 });
    }

    const toEdit: Record<string, unknown>[] = [];
    const toAdd: Record<string, unknown>[] = [];
    const results: Record<string, string> = {};

    for (const item of items ?? []) {
      const sheetRowId = rowIdMap.get(String(item.quotation_item_id));
      if (sheetRowId) {
        toEdit.push({ ID: sheetRowId, ...syncFields(item) });
        results[item.quotation_item_id] = "updated";
      } else {
        const quotation = quotationById.get(item.quotation_id);
        const orderDate = quotation?.created_at ? new Date(quotation.created_at).toISOString().slice(0, 10) : "";
        toAdd.push({
          "Job ID": quotation?.order_number || "",
          "Quotation_id": String(item.quotation_id ?? ""),
          "quotation_item_id": String(item.quotation_item_id),
          "License Plate": quotation?.plate_number || "",
          "Quantity": item.quantity ?? 0,
          "Order Date": orderDate,
          "Branch": branchByCustomer.get(item.customer_id) || "",
          ...syncFields(item),
        });
        results[item.quotation_item_id] = "added";
      }
    }

    if (toEdit.length > 0) await appsheetCall({ Action: "Edit", Properties: {}, Rows: toEdit });
    if (toAdd.length > 0) await appsheetCall({ Action: "Add", Properties: {}, Rows: toAdd });

    for (const id of missing) results[id] = "item_not_found";

    console.log(`bulk_update_items_in_sheet: ${toEdit.length} updated, ${toAdd.length} added, ${missing.length} missing from DB`);
    return new Response(
      JSON.stringify({ success: true, updated: toEdit.length, added: toAdd.length, missing_from_db: missing.length, results }),
      { status: 200 }
    );
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
