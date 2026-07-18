// supabase/functions/upload_bulk_rfq/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const supabase = createClient(supabaseUrl, supabaseKey);
serve(async (req)=>{
  try {
    // 🔑 Authenticate user
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
      return new Response(JSON.stringify({
        error: "Unauthorized"
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json"
        }
      });
    }
    // 📂 Parse multipart form data
    const formData = await req.formData();
    const bulk_file = formData.get("bulk_file");
    const uploaded_photo = formData.get("uploaded_photo");
    // Results object to collect uploaded files
    const results = {
      success: true
    };
    // 📝 Upload bulk_file if provided
    if (bulk_file && bulk_file.size > 0) {
      const ext = bulk_file.name.split(".").pop();
      const filePath = `uploads/${crypto.randomUUID()}.${ext}`;
      const { error: uploadError } = await supabase.storage.from("bulk_rfqs").upload(filePath, bulk_file.stream(), {
        contentType: bulk_file.type,
        upsert: true
      });
      if (uploadError) throw uploadError;
      const { data: publicUrlData } = supabase.storage.from("bulk_rfqs").getPublicUrl(filePath);
      results.bulk_file = {
        filePath,
        publicUrl: publicUrlData?.publicUrl || null
      };
    }
    // 🖼️ Upload uploaded_photo if provided
    if (uploaded_photo && uploaded_photo.size > 0) {
      const ext = uploaded_photo.name.split(".").pop();
      const filePath = `uploads/parts/${crypto.randomUUID()}.${ext}`;
      const { error: uploadError } = await supabase.storage.from("part_photos").upload(filePath, uploaded_photo.stream(), {
        contentType: uploaded_photo.type,
        upsert: true
      });
      if (uploadError) throw uploadError;
      const { data: publicUrlData } = supabase.storage.from("part_photos").getPublicUrl(filePath);
      results.uploaded_photo = {
        filePath,
        publicUrl: publicUrlData?.publicUrl || null
      };
    }
    // If neither file uploaded
    if (!results.bulk_file && !results.uploaded_photo) {
      return new Response(JSON.stringify({
        error: "No files uploaded"
      }), {
        status: 400,
        headers: {
          "Content-Type": "application/json"
        }
      });
    }
    return new Response(JSON.stringify(results), {
      status: 200,
      headers: {
        "Content-Type": "application/json"
      }
    });
  } catch (e) {
    return new Response(JSON.stringify({
      error: e.message
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json"
      }
    });
  }
});
