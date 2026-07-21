// supabase/functions/write_price_to_sheet/index.ts
// Syncs quotation_items.price_before_vat into the "Spare Part" AppSheet table's "unite price"
// column (and stamps "Delivery Status" as "Priced"), for a chunk of quotation_item_ids in one
// batched Find call. Mirrors bulk_update_items_in_sheet's batching pattern, but keeps this
// function's own narrower scope: only price + status are written, items with no
// price_before_vat yet are skipped, and items whose sheet row isn't found are skipped (never
// created) rather than added as new rows.
//
// Status and price are written as two SEPARATE batched Edit calls (one Edit covering every
// matched row's "Delivery Status", one Edit covering every matched row's "unite price") rather
// than one Edit per row setting both columns at once. AppSheet rejects an entire row's Edit if
// any single column on that row fails its own validation (e.g. "Delivery Status" landing on a
// value that row's workflow doesn't allow) - when status and price were combined in one Edit,
// a status validation failure on a row silently blocked that row's price write too. Splitting
// them means a status rejection on one row can no longer block that row's (or any other row's)
// price update, and vice versa.
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
// quotation_item_id (as string) -> AppSheet row key ("ID").
async function findRowIds(ids: (string | number)[]): Promise<Map<string, string>> {
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
  return map;
}

// Submits one column's worth of edits for the whole chunk in a single Edit call; if AppSheet
// rejects the whole batch (e.g. an invalid value on one row), retries each row individually so
// the rest still go through. Returns per-itemId success/failure, independent of any other
// column's batch.
async function submitEditBatch(
  rows: Array<{ itemId: number; row: Record<string, unknown> }>
): Promise<Record<number, true | string>> {
  const outcomes: Record<number, true | string> = {};
  if (rows.length === 0) return outcomes;
  try {
    await appsheetCall({ Action: "Edit", Properties: {}, Rows: rows.map((r) => r.row) });
    for (const r of rows) outcomes[r.itemId] = true;
  } catch (batchErr) {
    for (const r of rows) {
      try {
        await appsheetCall({ Action: "Edit", Properties: {}, Rows: [r.row] });
        outcomes[r.itemId] = true;
      } catch (rowErr) {
        outcomes[r.itemId] = String(rowErr);
      }
    }
  }
  return outcomes;
}

serve(async (req) => {
  try {
    const { quotation_item_ids } = await req.json();
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

    const { data: items, error } = await supabase
      .from("quotation_items")
      .select("quotation_item_id, price_before_vat")
      .in("quotation_item_id", ids);
    if (error) throw error;

    const itemById = new Map((items ?? []).map((i) => [i.quotation_item_id, i]));

    const results: Record<number, string> = {};
    const priced: Array<{ id: number; price: number }> = [];
    for (const id of ids) {
      const item = itemById.get(id);
      if (!item) {
        results[id] = "item not found";
        continue;
      }
      if (item.price_before_vat == null) {
        results[id] = "no price";
        continue;
      }
      priced.push({ id, price: item.price_before_vat });
    }

    const rowIdMap = priced.length ? await findRowIds(priced.map((p) => p.id)) : new Map<string, string>();

    const matched: Array<{ itemId: number; sheetRowId: string; price: number }> = [];
    for (const p of priced) {
      const sheetRowId = rowIdMap.get(String(p.id));
      if (!sheetRowId) {
        results[p.id] = "row not found in sheet";
        continue;
      }
      matched.push({ itemId: p.id, sheetRowId, price: p.price });
    }

    // Two independent batched Edit calls - one Edit covering every matched row's status, one
    // Edit covering every matched row's price - so a validation failure on one column for one
    // row can't block the other column's write for that row (see file header).
    const statusRows = matched.map((m) => ({ itemId: m.itemId, row: { ID: m.sheetRowId, "Delivery Status": "Priced" } }));
    const priceRows = matched.map((m) => ({ itemId: m.itemId, row: { ID: m.sheetRowId, "unite price": m.price } }));

    const [statusOutcomes, priceOutcomes] = await Promise.all([
      submitEditBatch(statusRows),
      submitEditBatch(priceRows),
    ]);

    for (const m of matched) {
      const priceOk = priceOutcomes[m.itemId] === true;
      const statusOk = statusOutcomes[m.itemId] === true;
      if (priceOk && statusOk) {
        results[m.itemId] = "written";
      } else if (priceOk && !statusOk) {
        results[m.itemId] = `written (status update failed: ${statusOutcomes[m.itemId]})`;
      } else if (!priceOk && statusOk) {
        results[m.itemId] = `failed: price update failed: ${priceOutcomes[m.itemId]}`;
      } else {
        results[m.itemId] = `failed: price update failed: ${priceOutcomes[m.itemId]}; status update failed: ${statusOutcomes[m.itemId]}`;
      }
    }

    const written = Object.values(results).filter((v) => v === "written" || v.startsWith("written (")).length;
    const failed = Object.values(results).filter((v) => v.startsWith("failed")).length;
    console.log(`write_price_to_sheet: ${written} written, ${failed} failed, ${ids.length - priced.length} skipped (not found/no price)`);

    return new Response(JSON.stringify({ success: true, results }), { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
