import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, x-client-info, Authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
  "Referrer-Policy": "strict-origin-when-cross-origin",
};

// UUID generator built into Deno
const generateUUID = () => crypto.randomUUID();

serve(async (req) => {
  // Handle preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    // Parse request form-data early
    const formData = await req.formData();

    // 🔑 Resolve auth
    const authHeader = req.headers.get("Authorization") ?? req.headers.get("authorization") ?? "";
    if (!authHeader || !authHeader.toLowerCase().startsWith("bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      });
    }
    const bearerToken = authHeader.replace(/^bearer\s+/i, "");
    const isServiceRoleCaller = bearerToken === supabaseKey;

    const admin = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { Authorization: `Bearer ${supabaseKey}` } }
    });
    let userId: string | null = null;
    if (isServiceRoleCaller) {
      // Server-to-server call: require explicit user_id in the form
      userId = formData.get("user_id")?.toString() ?? null;
      if (!userId) {
        return new Response(JSON.stringify({ error: "user_id is required when using service role key" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      }
    } else {
      // End-user flow: validate user token against GoTrue
      const authed = createClient(supabaseUrl, supabaseKey, {
        global: { headers: { Authorization: authHeader } }
      });
      const { data: { user }, error: userError } = await authed.auth.getUser();
      if (userError || !user) {
        console.error("Auth error:", userError);
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      }
      userId = user.id;
    }
    const fileEntry = formData.get("file");
    const file = fileEntry as File | null;
    const module_id = formData.get("module_id")?.toString() ?? null;
    const module_type = formData.get("module_type")?.toString() ?? null;
    const user_type = formData.get("user_type")?.toString() ?? null;
    const field_id = formData.get("field_id")?.toString() ?? null;
    if (!file || typeof (file as any).name !== 'string') {
      return new Response(JSON.stringify({
        error: "No file uploaded"
      }), {
        status: 400,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      });
    }
    const ext = file.name.split(".").pop();
    const typeSlugRaw = (module_type || 'misc').toLowerCase();
    const typeSlug = typeSlugRaw.endsWith('s') ? typeSlugRaw : `${typeSlugRaw}s`;
    const idSlug = module_id || '0';
    const fieldSlug = (field_id || 'general').toLowerCase();
    const filePath = `${typeSlug}/${idSlug}/${fieldSlug}/${generateUUID()}.${ext}`;
    // Upload file to storage
    const { error: uploadError } = await admin.storage.from("attachments")
      .upload(filePath, file, { contentType: (file as any).type || 'application/octet-stream' });
    if (uploadError) {
      console.error("Upload error:", uploadError);
      throw uploadError;
    }
    // Insert into DB via public RPC to avoid schema restriction
    const { data, error } = await admin.rpc('add_file_record', {
      p_module_id: module_id ? parseInt(module_id, 10) : 0,
      p_module_type: module_type,
      p_user_id: userId,
      p_user_type: user_type,
      p_field_id: field_id,
      p_file_path: filePath,
    });
    if (error) {
      console.error("full error:", JSON.stringify(error, null, 2));
      console.error("Insert error:", error, userId, {
        module_id: parseInt(module_id, 10),
        module_type,
        user_id: userId,
        user_type,
        file_path: filePath,
        field_id
      });
      return new Response(JSON.stringify({
        error: error.message,
        details: error
      }), {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      });
    }
    // Get public URL
    const { data: publicUrlData } = admin.storage.from("attachments").getPublicUrl(filePath);
    const publicUrl = publicUrlData?.publicUrl ?? null;
    return new Response(JSON.stringify({
      file: data,
      public_url: publicUrl
    }), {
      status: 200,
      headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  } catch (e) {
    console.error("Unhandled error:", e);
    return new Response(JSON.stringify({
      error: e.message
    }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }
});