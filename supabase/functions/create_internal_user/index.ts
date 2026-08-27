import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CreateInternalUserBody = {
  email: string;
  password: string;
  user_name: string;
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

    const body = (await req.json()) as CreateInternalUserBody;
    const email = String(body.email || "").trim();
    const password = String(body.password || "").trim();
    const userName = String(body.user_name || "").trim();
    const branchIds = Array.isArray(body.branch_ids) ? body.branch_ids.map(Number) : [];

    if (!email || !password || !userName) {
      return new Response(
        JSON.stringify({ status: "fail", message: "email, password and user_name are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (password.length < 6) {
      return new Response(
        JSON.stringify({ status: "fail", message: "Password must be at least 6 characters" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Any internal user (user_type = 185) can create a sub-user under their own company —
    // not gated on the Qparts Admin role specifically.
    const { data: callerData, error: callerDataError } = await supabaseAdmin
      .schema("qvm_new_apps")
      .from("user_data")
      .select("user_type, user_company")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();
    if (callerDataError) {
      return new Response(JSON.stringify({ status: "fail", message: callerDataError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: roleRows } = await supabaseAdmin
      .schema("qvm_new_apps")
      .from("list_data")
      .select("list_data_id, list_data, lists!inner(list_name)")
      .eq("lists.list_name", "user_role")
      .eq("list_data", "Internal Branch User");

    const internalBranchUserRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Internal Branch User")?.list_data_id;
    if (!internalBranchUserRoleId) {
      return new Response(JSON.stringify({ status: "fail", message: "Internal role lookup failed" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // Any internal user can create a sub-user under their own company — not just Qparts Admin.
    const isInternal = callerData?.user_type === 185;
    if (!isInternal) {
      return new Response(JSON.stringify({ status: "fail", message: "Not authorized" }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const companyId = callerData?.user_company;
    if (!companyId) {
      return new Response(JSON.stringify({ status: "fail", message: "Your account has no company assigned to inherit" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (branchIds.length > 0) {
      const { data: branchRows, error: branchError } = await supabaseAdmin
        .schema("qvm_new_apps")
        .from("client_branches")
        .select("customer_id")
        .eq("list_data_id", companyId)
        .in("customer_id", branchIds);
      if (branchError) {
        return new Response(JSON.stringify({ status: "fail", message: branchError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
      if ((branchRows ?? []).length !== branchIds.length) {
        return new Response(JSON.stringify({ status: "fail", message: "One or more branches do not belong to your company" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
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
        user_type: 185,
        user_role: internalBranchUserRoleId,
        user_company: companyId,
      });
    if (userDataError) {
      await supabaseAdmin.auth.admin.deleteUser(newUserId);
      return new Response(JSON.stringify({ status: "fail", message: userDataError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (branchIds.length > 0) {
      const { error: assignError } = await supabaseAdmin
        .schema("qvm_new_apps")
        .from("internal_user_branches")
        .insert(branchIds.map((branch_id) => ({ user_id: newUserId, branch_id, created_by: callerAuth.user.id })));
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
