// supabase/functions/activate_user_from_invite/index.ts
import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  const { access_token, refresh_token, new_password } = await req.json();
  if (!access_token || !refresh_token || !new_password) {
    return new Response(JSON.stringify({ error: "Missing fields" }), { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL"),
    Deno.env.get("SUPABASE_ANON_KEY"),
    {
      global: {
        headers: {
          Authorization: `Bearer ${access_token}`,
        },
      },
    }
  );

  const { error: sessionError } = await supabase.auth.setSession({
    access_token,
    refresh_token,
  });
  if (sessionError) {
    return new Response(JSON.stringify({ error: sessionError.message }), { status: 400 });
  }

  const { data, error: updateError } = await supabase.auth.updateUser({
    password: new_password,
  });

  if (updateError) {
    return new Response(JSON.stringify({ error: updateError.message }), { status: 400 });
  }

  return new Response(JSON.stringify({ message: "Password updated" }), { status: 200 });
});
