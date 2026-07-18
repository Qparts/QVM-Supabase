import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response("Not authorized", { status: 401 });
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace('Bearer ', "");
    const { data: userData, error: userError } = await supabaseAdmin.auth.getUser(jwt);

    if (userError || !userData.user) {
      return new Response("User not found", { status: 404 });
    }

    const { new_password } = await req.json();

    const { error } = await supabaseAdmin.auth.admin.updateUserById(userData.user.id, { password: new_password });
    if (error) {
      return new Response(JSON.stringify({ status: "fail", message: error.message }), { status: 403, headers: { "Content-Type": "application/json" } });
    }

    return new Response(
      JSON.stringify({ status: "success", message: "Password updated" }),
      { headers: { "Content-Type": "application/json" } }
    );

  } catch (error) {
    return new Response(JSON.stringify({ status: "error", message: error.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
