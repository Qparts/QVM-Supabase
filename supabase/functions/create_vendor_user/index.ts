import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CreateVendorUserBody = {
  vendor_id: number;
  email: string;
  password: string;
  user_name: string;
  role: "vendor_admin" | "vendor";
  branch_ids?: number[];
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response("Not authorized", { status: 401, headers: corsHeaders });
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: callerAuth, error: callerError } = await supabaseAdmin.auth.getUser(jwt);
    if (callerError || !callerAuth.user) {
      return new Response("User not found", { status: 404, headers: corsHeaders });
    }

    const body = (await req.json()) as CreateVendorUserBody;
    const vendorId = Number(body.vendor_id);
    const email = String(body.email || "").trim();
    // Default to the shared vendor password when the caller doesn't provide one, so vendors
    // created from any flow can log in immediately (QNEW). Stored hashed by the Admin API.
    const password = String(body.password || "").trim() || "123456";
    const userName = String(body.user_name || "").trim();
    const role = body.role;
    const branchIds = Array.isArray(body.branch_ids) ? body.branch_ids.map(Number) : [];

    if (!vendorId || !email || !password || !userName || (role !== "vendor_admin" && role !== "vendor")) {
      return new Response(
        JSON.stringify({ status: "fail", message: "vendor_id, email, password, user_name and a valid role are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Caller must be an internal Qparts staff member (bootstrapping the first admin-vendor for a
    // vendor account) OR already the admin-vendor of that same vendor account.
    const { data: callerData, error: callerDataError } = await supabaseAdmin
      .schema("qvm_new_apps")
      .from("user_data")
      .select("user_type, user_vendor, user_role")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();
    if (callerDataError) {
      return new Response(JSON.stringify({ status: "fail", message: callerDataError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: roleRows } = await supabaseAdmin
      .schema("qvm_new_apps")
      .from("list_data")
      .select("list_data_id, list_data, list_id, lists!inner(list_name)")
      .eq("lists.list_name", "user_role")
      .in("list_data", ["Vendor Admin", "Vendor"]);

    const vendorAdminRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Vendor Admin")?.list_data_id;
    const vendorRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Vendor")?.list_data_id;
    if (!vendorAdminRoleId || !vendorRoleId) {
      return new Response(JSON.stringify({ status: "fail", message: "Vendor role lookup failed" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const isInternal = String(callerData?.user_type ?? "") === "185";
    const isAdminVendorForThisVendor = callerData?.user_vendor === vendorId && callerData?.user_role === vendorAdminRoleId;
    if (!isInternal && !isAdminVendorForThisVendor) {
      return new Response(JSON.stringify({ status: "fail", message: "Not authorized" }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (role === "vendor" && branchIds.length > 0) {
      const { data: branchRows, error: branchError } = await supabaseAdmin
        .schema("qvm_new_apps")
        .from("vendor_branches")
        .select("vendor_branch_id")
        .eq("vendor_id", vendorId)
        .in("vendor_branch_id", branchIds);
      if (branchError) {
        return new Response(JSON.stringify({ status: "fail", message: branchError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
      if ((branchRows ?? []).length !== branchIds.length) {
        return new Response(JSON.stringify({ status: "fail", message: "One or more branches do not belong to this vendor" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
    }

    const { data: created, error: createError } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (createError || !created.user) {
      return new Response(JSON.stringify({ status: "fail", message: createError?.message ?? "Failed to create user" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const newUserId = created.user.id;

    const { error: userDataError } = await supabaseAdmin
      .schema("qvm_new_apps")
      .from("user_data")
      .insert({
        user_id: newUserId,
        email,
        user_name: userName,
        user_type: 205,
        user_role: role === "vendor_admin" ? vendorAdminRoleId : vendorRoleId,
        user_vendor: vendorId,
      });
    if (userDataError) {
      await supabaseAdmin.auth.admin.deleteUser(newUserId);
      return new Response(JSON.stringify({ status: "fail", message: userDataError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (role === "vendor" && branchIds.length > 0) {
      const { error: assignError } = await supabaseAdmin
        .schema("qvm_new_apps")
        .from("vendor_branch_users")
        .insert(branchIds.map((vendor_branch_id) => ({ user_id: newUserId, vendor_branch_id })));
      if (assignError) {
        return new Response(JSON.stringify({ status: "fail", message: assignError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
    }

    return new Response(
      JSON.stringify({ status: "success", user_id: newUserId }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    return new Response(JSON.stringify({ status: "error", message: error.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
