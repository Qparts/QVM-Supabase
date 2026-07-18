// supabase/functions/write_price_to_sheet/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_ID = Deno.env.get("APPSHEET_APP_ID")!;
const ACCESS_KEY = Deno.env.get("APPSHEET_ACCESS_KEY")!;
const TABLE_NAME = Deno.env.get("APPSHEET_TABLE_NAME") ?? "Spare Part";

const APPSHEET_BASE = `https://api.appsheet.com/api/v2/apps/${APP_ID}/tables/${encodeURIComponent(TABLE_NAME)}/Action`;

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

// Step 1: find the row by quotation_item_id, return its Key (ID) value
async function findRowKey(quotationItemId: string | number): Promise<string | null> {
  const escaped = String(quotationItemId).replace(/"/g, '\\"');
  const result = await appsheetCall({
    Action: "Find",
    Properties: {
      Selector: `FILTER("${TABLE_NAME}", [quotation_item_id]="${escaped}")`,
    },
    Rows: [],
  });

  if (!Array.isArray(result) || result.length === 0) return null;
  return result[0]["ID"] ?? null;
}

// Step 2: edit that row's price + status columns
async function editRow(rowKey: string, price: number) {
  await appsheetCall({
    Action: "Edit",
    Properties: {},
    Rows: [
      {
        ID: rowKey,
        "unite price": price,
        "Delivery Status": "Priced",
      },
    ],
  });
}

serve(async (req) => {
  try {
    const { quotation_item_ids } = await req.json();
    if (!Array.isArray(quotation_item_ids) || quotation_item_ids.length === 0) {
      return new Response(JSON.stringify({ error: "quotation_item_ids required" }), { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    ).schema("qvm_new_apps");

    const results: Record<string, string> = {};

    for (const item_id of quotation_item_ids) {
      const { data: item, error } = await supabase
        .from("quotation_items")
        .select("price_before_vat")
        .eq("quotation_item_id", item_id)
        .maybeSingle();

      if (error || !item) {
        console.error(`Skipping ${item_id}, fetch failed`, error);
        results[item_id] = "item not found";
        continue;
      }

      const selling_price = item.price_before_vat;
      if (selling_price == null) {
        console.log(`No price_before_vat yet for item ${item_id}, skipping sheet write`);
        results[item_id] = "no price";
        continue;
      }

      const rowKey = await findRowKey(item_id);
      if (!rowKey) {
        console.error(`No sheet row found for quotation_item_id ${item_id}`);
        results[item_id] = "row not found in sheet";
        continue;
      }

      await editRow(rowKey, selling_price);
      results[item_id] = "written";
    }

    return new Response(JSON.stringify({ success: true, results }), { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
