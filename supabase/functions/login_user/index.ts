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
    // IMPORTANT: do NOT forward the caller's Authorization header here.
    // supabase-js's functions.invoke() automatically attaches the browser's *stored* access
    // token as `Authorization: Bearer <jwt>`. If that token is stale/expired (a leftover from a
    // previous session in localStorage), forwarding it to GoTrue's /token endpoint makes it reject
    // the request as an invalid/expired token BEFORE the password is ever checked — so login keeps
    // failing until the user clears their browser cache or switches browser. signInWithPassword
    // only needs the anon apikey, which createClient sends on its own. Always use a clean anon
    // client with no forwarded user token, and don't persist any state on the server.
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
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
