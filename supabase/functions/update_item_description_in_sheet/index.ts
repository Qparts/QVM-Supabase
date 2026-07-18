// supabase/functions/update_item_description_in_sheet/index.ts
// Updates the "Part Description" column of the matching row in the "Spare Part" AppSheet sheet
// when a quotation item's part_description changes. AppSheet's key column ("ID") is auto-generated
// by the sheet itself (not something we control or send on Add), so the row is located first via a
// Find action matching on "Quotation_item_ID" (the same column write_item_to_sheet populates),
// then edited using the real ID that Find returns.
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

async function findRowId(quotationItemId: number): Promise<string | null> {
  const result = await appsheetCall({
    Action: "Find",
    Properties: {
      Selector: `Filter("${TABLE_NAME}", [Quotation_item_ID] = "${quotationItemId}")`,
    },
    Rows: [],
  });
  if (Array.isArray(result) && result.length > 0) {
    return result[0]?.ID ?? null;
  }
  return null;
}

serve(async (req) => {
  try {
    const { quotation_item_id } = await req.json();
    if (!quotation_item_id) {
      return new Response(JSON.stringify({ error: "quotation_item_id required" }), { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    ).schema("qvm_new_apps");

    const { data: item, error: itemErr } = await supabase
      .from("quotation_items")
      .select("quotation_item_id, part_description")
      .eq("quotation_item_id", quotation_item_id)
      .maybeSingle();

    if (itemErr || !item) {
      console.error("Item fetch failed:", itemErr);
      return new Response(JSON.stringify({ error: "Item not found" }), { status: 404 });
    }

    const rowId = await findRowId(quotation_item_id);
    if (!rowId) {
      console.error(`No sheet row found for quotation_item_id ${quotation_item_id}`);
      return new Response(JSON.stringify({ error: "Row not found in sheet for this item" }), { status: 404 });
    }

    await appsheetCall({
      Action: "Edit",
      Properties: {},
      Rows: [
        {
          ID: rowId,
          "Part Description": item.part_description || "",
        },
      ],
    });

    console.log(`Part Description updated for quotation_item_id ${quotation_item_id} (row ID ${rowId}): ${item.part_description}`);
    return new Response(JSON.stringify({ success: true, quotation_item_id, part_description: item.part_description }), { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
