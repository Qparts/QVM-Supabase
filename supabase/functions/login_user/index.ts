// File: supabase/functions/login_user/index.ts
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
serve(async (req)=>{
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders
    });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !supabaseAnonKey) {
      return new Response(JSON.stringify({
        error: "Missing Supabase env vars"
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }

    const { email, password } = await req.json();
    if (!email || !password) {
      return new Response(JSON.stringify({
        error: "Missing email or password"
      }), {
        status: 400,
        headers: corsHeaders
      });
    }
    // Use the authorization header from the request if provided
    const authHeader = req.headers.get("Authorization");
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader || `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}`
        }
      }
    });
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password
    });
    if (error) {
      const msg = (error.message || "").toLowerCase();
      const invalidCreds = msg.includes("invalid") || msg.includes("credentials") || msg.includes("email") || msg.includes("password");
      return new Response(JSON.stringify({
        error: invalidCreds ? "Invalid email or password" : error.message
      }), {
        status: 401,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }

    return new Response(JSON.stringify({
      access_token: data.session?.access_token,
      refresh_token: data.session?.refresh_token,
      user_id: data.user?.id,
      email: data.user?.email
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    console.error('login_user unexpected error:', err);
    return new Response(JSON.stringify({
      error: "Unexpected error",
      details: err.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
 });
