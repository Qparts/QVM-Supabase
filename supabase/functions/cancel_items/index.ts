// supabase/functions/update_rfq_item_status/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Server is misconfigured" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const token = authHeader.replace("Bearer ", "");
  const { data: authData, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !authData?.user) {
    return new Response(JSON.stringify({ error: "Invalid session" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const userId = authData.user.id;

  const body = await req.json();
  const action = typeof body?.action === "string" ? body.action : null;
  if (action === "get_cancellation_reasons") {
    const listIdRaw = body?.list_id;
    const listId = typeof listIdRaw === "string" || typeof listIdRaw === "number" ? Number(listIdRaw) : NaN;
    if (!Number.isFinite(listId)) {
      return new Response(JSON.stringify({ error: "Missing or invalid input (list_id)" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data, error } = await supabaseAdmin.rpc('get_list_data_by_list_ids', {
      p_list_ids: [listId],
    });

    if (error) {
      console.error("❌ Error fetching cancellation reasons:", error);
      return new Response(JSON.stringify({ error: error.message || "Failed to load cancellation reasons" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const rows = Array.isArray(data) ? data : [];
    const mapped = rows
      .filter((r: any) => Number(r?.list_id) === Number(listId))
      .map((r: any) => ({ list_data_id: r?.list_data_id ?? null, list_data: r?.label ?? null }));

    return new Response(JSON.stringify({ success: true, data: mapped }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const quotation_item_ids = (body?.quotation_item_ids ?? body?.quotation_item_id ?? []) as unknown;
  const cancellationReasonIdRaw = (body?.cancellation_reason_id ?? body?.cancellation_reason ?? null) as unknown;
  const new_status = 18; // 🔒 Constant status: Canceled

  const itemIds = Array.isArray(quotation_item_ids) ? quotation_item_ids : [quotation_item_ids];
  const normalizedItemIds = itemIds
    .map((v) => (typeof v === "string" || typeof v === "number" ? Number(v) : NaN))
    .filter((n) => Number.isFinite(n));

  const cancellation_reason_id =
    typeof cancellationReasonIdRaw === "string" || typeof cancellationReasonIdRaw === "number"
      ? Number(cancellationReasonIdRaw)
      : null;

  if (!Array.isArray(itemIds) || normalizedItemIds.length === 0) {
    return new Response(
      JSON.stringify({
        error: "Missing or invalid input (quotation_item_ids)",
      }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const supabaseRpc = createClient(supabaseUrl, serviceRoleKey, {
    global: {
      headers: {
        Authorization: authHeader,
      },
    },
  });

  const { data: rpcData, error: rpcErr } = await supabaseRpc.rpc('cancel_rfq_items', {
    p_quotation_item_ids: normalizedItemIds,
    p_cancellation_reason: Number.isFinite(cancellation_reason_id as number) ? cancellation_reason_id : null,
  });

  if (rpcErr) {
    console.error('❌ cancel_rfq_items RPC error:', rpcErr);
    return new Response(JSON.stringify({ error: rpcErr.message || 'Failed to cancel items' }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (rpcData && typeof rpcData === 'object' && (rpcData as any).success === false) {
    return new Response(JSON.stringify({ error: String((rpcData as any).error ?? 'Failed to cancel items') }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ success: true, data: rpcData ?? null }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
