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

    // Use provided order number if present, otherwise generate one
    let finalOrderNumber: string | null =
      typeof order_number === 'string' && order_number.trim() !== ''
        ? order_number.trim()
        : null;

    if (!finalOrderNumber) {
      const { data: generatedOrderNumber, error: orderErr } = await supabase
        .rpc("generate_rfq_order_number", {
          p_client_id: client_id,
          p_region_id: region_id,
        });

      if (orderErr) throw orderErr;
      finalOrderNumber = generatedOrderNumber as string;
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

    // Create quotation
    const { data: quotation, error: qErr } = await supabase
      .rpc('create_quotation', {
        p_account_manager: account_manager,
        p_delivery_type: delivery_type,
        p_order_number: finalOrderNumber,
        p_order_type: order_type,
        p_plate_number: plate_number,
        p_service_advisor: service_advisor,
        p_insurance_company_id: insurance_company_id ?? null,
      })
      .single();

    if (qErr) throw qErr;

    // Type assertion for quotation
    const typedQuotation = quotation as {
      quotation_id: number;
      order_number: string;
    };

    // Determine initial status based on part number presence
    const getItemStatus = (partNumber?: string | null) => {
      return partNumber && partNumber.trim() !== '' ? 235 : 236;
    };

    // Prepare items with estimated prices
    const itemsPayload = await Promise.all(
      items.map(async (item: any) => {
        const { data: estPriceData, error: estErr } = await supabase
          .rpc("get_estimated_price", {
            p_brand_class_id: item.brand_class,
            p_client_id: client_id,
            p_part_number: item.part_number,
          });
        
        if (estErr) throw estErr;
        console.log("estimated price error: ", estErr, "estimated price value: ", estPriceData);

        return {
          quotation_id: typedQuotation.quotation_id,
          customer_id,
          vin: item.vin ?? null,
          main_brand: item.main_brand,
          model: item.model ?? null,
          part_number: item.part_number ?? null,
          part_description: item.part_description ?? null,
          quantity: item.quantity,
          brand_class: item.brand_class,
          part_photo: item.part_photo ?? null,
          item_status: getItemStatus(item.part_number),
          item_PK: item.item_PK ?? null,
          estimated_price: estPriceData,
        };
      })
    );

    // Create quotation items
    const { data: insertedItems, error: itemsErr } = await supabase
      .rpc('create_quotation_items', {
        p_items: itemsPayload
      });

    if (itemsErr) throw itemsErr;

    // Add note if exists
    if (notes) {
      await supabase
        .rpc('create_quotation_note', {
          p_type_id: typedQuotation.quotation_id,
          p_note: notes,
          p_user_id: service_advisor
        });
    }

    // Build items list from inserted rows to include quotation_item_id
    const itemsResponse = Array.isArray(insertedItems)
      ? insertedItems.map((row: any) => ({
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
        quotation_id: typedQuotation.quotation_id,
        order_number: typedQuotation.order_number,
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
