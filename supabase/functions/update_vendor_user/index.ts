import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type UpdateVendorUserBody = {
  user_id: string;
  user_name?: string;
  email?: string;
  role?: "vendor_admin" | "vendor";
  branch_ids?: number[];
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

    const body = (await req.json()) as UpdateVendorUserBody;
    const targetUserId = String(body.user_id || "");
    if (!targetUserId) return jsonResponse({ status: "fail", message: "user_id is required" }, 400);

    const db = supabaseAdmin.schema("qvm_new_apps");

    const { data: target, error: targetError } = await db
      .from("user_data")
      .select("user_id, user_vendor, user_role, email, user_name")
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
    const vendorRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Vendor")?.list_data_id;
    if (!vendorAdminRoleId || !vendorRoleId) return jsonResponse({ status: "fail", message: "Vendor role lookup failed" }, 500);

    const isInternal = String(callerData?.user_type ?? "") === "185";
    const isAdminVendorForThisVendor = callerData?.user_vendor === target.user_vendor && callerData?.user_role === vendorAdminRoleId;
    if (!isInternal && !isAdminVendorForThisVendor) return jsonResponse({ status: "fail", message: "Not authorized" }, 403);

    const newRoleId = body.role === "vendor_admin" ? vendorAdminRoleId : body.role === "vendor" ? vendorRoleId : undefined;

    // Guard: never leave a vendor account with zero admins.
    if (newRoleId !== undefined && target.user_role === vendorAdminRoleId && newRoleId !== vendorAdminRoleId) {
      const { count } = await db
        .from("user_data")
        .select("user_id", { count: "exact", head: true })
        .eq("user_vendor", target.user_vendor)
        .eq("user_role", vendorAdminRoleId)
        .neq("user_id", targetUserId);
      if (!count) return jsonResponse({ status: "fail", message: "Cannot demote the only admin-vendor — promote another user first" }, 400);
    }

    if (body.branch_ids && body.branch_ids.length > 0) {
      const { data: branchRows, error: branchError } = await db
        .from("vendor_branches")
        .select("vendor_branch_id")
        .eq("vendor_id", target.user_vendor)
        .in("vendor_branch_id", body.branch_ids);
      if (branchError) return jsonResponse({ status: "fail", message: branchError.message }, 500);
      if ((branchRows ?? []).length !== body.branch_ids.length) {
        return jsonResponse({ status: "fail", message: "One or more branches do not belong to this vendor" }, 400);
      }
    }

    const newEmail = body.email?.trim();
    if (newEmail && newEmail !== target.email) {
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(targetUserId, { email: newEmail });
      if (authUpdateError) return jsonResponse({ status: "fail", message: authUpdateError.message }, 400);
    }

    const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
    if (body.user_name?.trim()) updates.user_name = body.user_name.trim();
    if (newEmail) updates.email = newEmail;
    if (newRoleId !== undefined) updates.user_role = newRoleId;

    const { error: updateError } = await db.from("user_data").update(updates).eq("user_id", targetUserId);
    if (updateError) return jsonResponse({ status: "fail", message: updateError.message }, 500);

    if (newRoleId === vendorAdminRoleId) {
      // Admin-vendor gets implicit access to every branch — no explicit rows needed.
      await db.from("vendor_branch_users").delete().eq("user_id", targetUserId);
    } else if (body.branch_ids) {
      await db.from("vendor_branch_users").delete().eq("user_id", targetUserId);
      if (body.branch_ids.length > 0) {
        await db.from("vendor_branch_users").insert(body.branch_ids.map((vendor_branch_id) => ({ user_id: targetUserId, vendor_branch_id })));
      }
    }

    return jsonResponse({ status: "success" });
  } catch (error) {
    return jsonResponse({ status: "error", message: error.message }, 500);
  }
});
