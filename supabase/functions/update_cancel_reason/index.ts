// File: supabase/functions/update_cancel_reasons/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL"),
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  ).schema("qvm_new_apps");

  const updates = await req.json(); // Expected: [{ quotation_item_id, cancellation_reason }, ...]

  if (!Array.isArray(updates)) {
    return new Response(
      JSON.stringify({ error: "Invalid input, expected an array" }),
      { status: 400 }
    );
  }

  const errors = [];

  for (const row of updates) {
    const { quotation_item_id, cancellation_reason } = row;

    if (!quotation_item_id || cancellation_reason === undefined) {
      errors.push({
        quotation_item_id,
        error: "Missing fields",
      });
      continue;
    }

    const { error } = await supabase
      .from("quotation_items")
      .update({ cancellation_reason })
      .eq("quotation_item_id", quotation_item_id);

    if (error) {
      console.error(`❌ Failed to update item ${quotation_item_id}:`, error);
      errors.push({
        quotation_item_id,
        error: error.message,
      });
    }
  }

  return new Response(
    JSON.stringify({
      success: errors.length === 0,
      errors,
    }),
    { status: 200 }
  );
});
