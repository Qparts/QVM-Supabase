// supabase/functions/update_rfq_item_status/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")).schema('qvm_new_apps');
  const { user_id, new_status, quotation_item_ids } = await req.json();
  if (!user_id || !new_status || !Array.isArray(quotation_item_ids)) {
    return new Response(JSON.stringify({
      error: "Missing or invalid input"
    }), {
      status: 400
    });
  }
  for (const item_id of quotation_item_ids){
    // 1. Update rfq_items status
    const { error: updateErr } = await supabase.from("quotation_items").update({
      item_status: new_status
    }).eq("quotation_item_id", item_id);
    if (updateErr) {
      console.error(`Error updating item ${item_id}:`, updateErr);
      continue;
    }
    // 2. Log status change
    await supabase.from("status_logs").insert({
      quotation_item_id: item_id,
      item_status: new_status,
      status_changed_by: user_id
    });
    // 3. If status is Confirmed → create confirmed_order and confirmed_item
    if (new_status === 19) {
      const { data: item, error: itemErr } = await supabase.from("quotation_items").select("quotation_id, pricing_id, part_description, part_number, quantity").eq("quotation_item_id", item_id).maybeSingle();
      if (!item || itemErr) {
        console.error(`Failed to fetch item ${item_id}`, itemErr);
        continue;
      }
      // Check if a confirmed_order already exists
      const { data: existingOrder } = await supabase.from("confirmed_orders").select("confirmed_order_id").eq("rfq_id", item.rfq_id).maybeSingle();
      let confirmed_order_id;
      if (existingOrder?.confirmed_order_id) {
        confirmed_order_id = existingOrder.confirmed_order_id;
      } else {
        // Insert new confirmed_order
        const { data: newOrder, error: insertOrderErr } = await supabase.from("confirmed_orders").insert({
          rfq_id: item.rfq_id
        }).select("confirmed_order_id").single();
        if (insertOrderErr || !newOrder) {
          console.error("Failed to create confirmed_order", insertOrderErr);
          continue;
        }
        confirmed_order_id = newOrder.confirmed_order_id;
      }
      // Get final_part_number
      let final_part_number = item.part_number;
      if (item.pricing_id) {
        const { data: vendorItem } = await supabase.from("quotation_vendor_item").select("alternative_part_number").eq("pricing_id", item.pricing_id).maybeSingle();
        if (vendorItem?.alternative_part_number) {
          final_part_number = vendorItem.alternative_part_number;
        }
      }
      // Insert into confirmed_items
      await supabase.from("confirmed_items").insert({
        confirmed_order_id,
        quotation_item_id: item_id,
        pricing_id: item.pricing_id,
        part_description: item.part_description,
        final_part_number,
        approved_qty: item.quantity,
        item_status: new_status
      });
    }
  }
  return new Response(JSON.stringify({
    success: true
  }), {
    status: 200
  });
});
