import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, x-client-info, Authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
  "Referrer-Policy": "strict-origin-when-cross-origin",
};

interface ReassignOrdersRequest {
  quotation_ids: number[];
  user_id: string;
}

interface ReassignOrdersResponse {
  status: string;
  message: string;
  reassigned_count: number;
}

Deno.serve(async (req) => {
  // Handle preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { quotation_ids, user_id }: ReassignOrdersRequest = await req.json();

    if (!quotation_ids || !Array.isArray(quotation_ids) || quotation_ids.length === 0) {
      return new Response(JSON.stringify({
        status: 'error',
        message: 'Please Select the items/Orders You want to reassign.',
        reassigned_count: 0
      }), {
        status: 400,
        headers: { "Content-Type": "application/json", ...corsHeaders },
      });
    }

    // Call the database RPC function
    const { data, error } = await supabase.rpc('reassign_orders_rpc', {
      p_quotation_ids: quotation_ids,
      p_user_id: user_id
    });

    if (error) {
      console.error('RPC error:', error);
      return new Response(JSON.stringify({
        status: 'error',
        message: error.message || 'Failed to reassign orders',
        reassigned_count: 0
      }), {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders },
      });
    }

    return new Response(JSON.stringify(data), {
      status: data.status === 'success' ? 200 : 400,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });

  } catch (error) {
    console.error('Reassign orders error:', error);
    return new Response(JSON.stringify({
      status: 'error',
      message: 'Internal server error',
      reassigned_count: 0
    }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  }
});
