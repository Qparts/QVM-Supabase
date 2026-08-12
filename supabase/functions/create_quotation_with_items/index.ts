import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, x-client-info, Authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
  "Referrer-Policy": "strict-origin-when-cross-origin",
};

// Handle OPTIONS requests for CORS preflight
const handleOptions = () => {
  return new Response("ok", { 
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
      "Access-Control-Allow-Headers": "content-type, authorization",
    }
  });
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return handleOptions();
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({
        status: false, 
        message: "Unauthorized", 
        data: null 
      }), { 
        status: 401,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    const { data: authData, error: authError } =
      await supabase.auth.getUser(authHeader.replace("Bearer ", ""));

    if (authError || !authData?.user) {
      return new Response(JSON.stringify({
        status: false, 
        message: "Invalid session", 
        data: null 
      }), { 
        status: 401,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    const service_advisor = authData.user.id;
    const body = await req.json();

    const {
      plate_number,
      order_type,
      delivery_type,
      customer_id,
      client_id,
      order_number,
      items,
      notes,
      insurance_company_id,
    } = body;

    // Get region_id for branch using RPC
    const { data: regionData, error: regionErr } = await supabase
      .rpc('get_region_for_branch', { p_customer_id: customer_id });

    if (regionErr || !regionData) {
      return new Response(JSON.stringify({
        status: false,
        message: 'Region not found for this branch',
        data: null
      }), {
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    const region_id = regionData;

    if (!client_id || !customer_id || !region_id || !order_type || !delivery_type) {
      return new Response(JSON.stringify({
        status: false, 
        message: "Missing required fields", 
        data: null 
      }), { 
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    if (!Array.isArray(items) || items.length === 0) {
      return new Response(JSON.stringify({
        status: false, 
        message: "Items are required", 
        data: null 
      }), { 
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    // Get account manager
    const { data: amResult, error: amErr } = await supabase.functions.invoke(
      "get_account_manager",
      {
        body: { customer_id },
        headers: { Authorization: authHeader },
      }
    );

    if (amErr || !amResult?.status) {
      return new Response(JSON.stringify({
        status: false, 
        message: amResult?.message || "Account manager error", 
        data: amErr 
      }), { 
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }

    const account_manager = amResult.data.account_manager;

    // Quotation + items + note are created atomically in a single DB transaction (order-number
    // resolution/uniqueness included) — see qvm_new_apps.create_quotation_with_items. This
    // replaces what used to be three separate, independently-committing RPC calls, which could
    // (and did) leave an orphaned quotation row with zero items if anything failed partway
    // through, and had no protection at all against two callers using the same order_number.
    const { data: result, error: createErr } = await supabase
      .schema('qvm_new_apps')
      .rpc('create_quotation_with_items', {
        p_account_manager: account_manager,
        p_delivery_type: delivery_type,
        p_order_type: order_type,
        p_plate_number: plate_number,
        p_service_advisor: service_advisor,
        p_client_id: client_id,
        p_region_id: region_id,
        p_customer_id: customer_id,
        p_items: items,
        p_insurance_company_id: insurance_company_id ?? null,
        p_order_number: typeof order_number === 'string' ? order_number.trim() || null : null,
        p_notes: notes ?? null,
      });

    if (createErr) {
      // Postgres unique_violation on quotations.order_number — a caller (typically a third-party
      // integration supplying its own order_number) reused one that already exists. Surface this
      // distinctly so the caller can tell "duplicate order number" apart from a generic failure,
      // instead of a flat 500.
      if (createErr.code === '23505') {
        return new Response(JSON.stringify({
          status: false,
          message: 'Order number already exists',
          data: null
        }), {
          status: 409,
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
      throw createErr;
    }

    const typedResult = result as {
      quotation_id: number;
      order_number: string;
      items: Array<{
        quotation_item_id: number;
        part_number: string | null;
        part_description: string | null;
        estimated_price: number | null;
        item_pk: string | null;
        part_photo: string | null;
      }>;
    };

    const itemsResponse = Array.isArray(typedResult.items)
      ? typedResult.items.map((row) => ({
          quotation_item_id: row.quotation_item_id,
          part_number: row.part_number,
          part_description: row.part_description,
          estimated_price: row.estimated_price,
          item_pk: row.item_pk ?? null,
          part_photo: row.part_photo ?? null,
        }))
      : [];

    // Success response
    return new Response(JSON.stringify({
      status: true,
      message: "RFQ created successfully",
      data: {
        quotation_id: typedResult.quotation_id,
        order_number: typedResult.order_number,
        account_manager,
        items: itemsResponse,
      },
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });

  } catch (err: any) {
    console.error("Error in create_quotation_with_items:", err);
    return new Response(JSON.stringify({
      status: false,
      message: err.message || "Unexpected error",
      data: null
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  }
});
