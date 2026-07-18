import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response("Not authorized", { status: 401, headers: corsHeaders });

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: callerAuth, error: callerError } = await supabaseAdmin.auth.getUser(jwt);
    if (callerError || !callerAuth.user) return new Response("User not found", { status: 404, headers: corsHeaders });

    const body = await req.json();
    const targetUserId = String(body?.user_id || "");
    if (!targetUserId) return jsonResponse({ status: "fail", message: "user_id is required" }, 400);

    if (targetUserId === callerAuth.user.id) {
      return jsonResponse({ status: "fail", message: "You cannot delete your own login" }, 400);
    }

    const db = supabaseAdmin.schema("qvm_new_apps");

    const { data: target, error: targetError } = await db
      .from("user_data")
      .select("user_id, user_vendor, user_role")
      .eq("user_id", targetUserId)
      .maybeSingle();
    if (targetError) return jsonResponse({ status: "fail", message: targetError.message }, 500);
    if (!target?.user_vendor) return jsonResponse({ status: "fail", message: "Vendor user not found" }, 404);

    const { data: callerData, error: callerDataError } = await db
      .from("user_data")
      .select("user_type, user_vendor, user_role")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();
    if (callerDataError) return jsonResponse({ status: "fail", message: callerDataError.message }, 500);

    const { data: roleRows } = await db
      .from("list_data")
      .select("list_data_id, list_data, list_id, lists!inner(list_name)")
      .eq("lists.list_name", "user_role")
      .in("list_data", ["Vendor Admin", "Vendor"]);
    const vendorAdminRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Vendor Admin")?.list_data_id;
    if (!vendorAdminRoleId) return jsonResponse({ status: "fail", message: "Vendor role lookup failed" }, 500);

    const isInternal = String(callerData?.user_type ?? "") === "185";
    const isAdminVendorForThisVendor = callerData?.user_vendor === target.user_vendor && callerData?.user_role === vendorAdminRoleId;
    if (!isInternal && !isAdminVendorForThisVendor) return jsonResponse({ status: "fail", message: "Not authorized" }, 403);

    // Guard: never leave a vendor account with zero admins.
    if (target.user_role === vendorAdminRoleId) {
      const { count } = await db
        .from("user_data")
        .select("user_id", { count: "exact", head: true })
        .eq("user_vendor", target.user_vendor)
        .eq("user_role", vendorAdminRoleId)
        .neq("user_id", targetUserId);
      if (!count) return jsonResponse({ status: "fail", message: "Cannot delete the only admin-vendor — promote another user first" }, 400);
    }

    const { error: deleteDataError } = await db.from("user_data").delete().eq("user_id", targetUserId);
    if (deleteDataError) return jsonResponse({ status: "fail", message: deleteDataError.message }, 500);

    const { error: deleteAuthError } = await supabaseAdmin.auth.admin.deleteUser(targetUserId);
    if (deleteAuthError) return jsonResponse({ status: "fail", message: deleteAuthError.message }, 500);

    return jsonResponse({ status: "success" });
  } catch (error) {
    return jsonResponse({ status: "error", message: error.message }, 500);
  }
});
