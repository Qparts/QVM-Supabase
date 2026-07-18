// supabase/functions/upload_part_photos/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, supabaseKey);

// Common CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};

serve(async (req: Request) => {
  // 🔹 Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // 🔑 Authenticate user
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      });
    }

    // 📂 Parse multipart form data
    const formData = await req.formData();
    const uploads: any[] = [];

    for (const [field, file] of formData.entries()) {
      if (!(file instanceof File)) continue; // skip non-files

      const ext = file.name.split(".").pop();
      const filePath = `uploads/parts/${crypto.randomUUID()}.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from("part_photos")
        .upload(filePath, file.stream(), {
          contentType: file.type,
          upsert: true
        });

      if (uploadError) throw uploadError;

      const { data: publicUrlData } = supabase.storage
        .from("part_photos")
        .getPublicUrl(filePath);

      uploads.push({
        field,
        url: publicUrlData?.publicUrl ?? null,
        filePath
      });
    }

    return new Response(JSON.stringify({ success: true, uploads }), {
      status: 200,
      headers: { "Content-Type": "application/json", ...corsHeaders }
    });

  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }
});
