import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type UpdateInternalUserBody = {
  user_id: string;
  user_name?: string;
  email?: string;
  password?: string;
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

    const body = (await req.json()) as UpdateInternalUserBody;
    const targetUserId = String(body.user_id || "");
    if (!targetUserId) return jsonResponse({ status: "fail", message: "user_id is required" }, 400);

    const db = supabaseAdmin.schema("qvm_new_apps");

    const { data: target, error: targetError } = await db
      .from("user_data")
      .select("user_id, user_type, user_role, user_company, email")
      .eq("user_id", targetUserId)
      .maybeSingle();
    if (targetError) return jsonResponse({ status: "fail", message: targetError.message }, 500);
    if (!target || target.user_type !== 185) return jsonResponse({ status: "fail", message: "Internal user not found" }, 404);

    const { data: callerData, error: callerDataError } = await db
      .from("user_data")
      .select("user_type, user_company")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();
    if (callerDataError) return jsonResponse({ status: "fail", message: callerDataError.message }, 500);

    const isInternal = callerData?.user_type === 185;
    const sameCompany = callerData?.user_company != null && callerData.user_company === target.user_company;
    if (!isInternal || !sameCompany) return jsonResponse({ status: "fail", message: "Not authorized" }, 403);

    // Qparts Admin accounts cannot be edited from this page either.
    const { data: roleRows } = await db
      .from("list_data")
      .select("list_data_id, list_data, lists!inner(list_name)")
      .eq("lists.list_name", "user_role")
      .eq("list_data", "Qparts Admin");
    const qpartsAdminRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Qparts Admin")?.list_data_id;
    if (qpartsAdminRoleId && target.user_role === qpartsAdminRoleId) {
      return jsonResponse({ status: "fail", message: "Qparts Admin accounts cannot be updated from this page" }, 400);
    }

    if (body.branch_ids && body.branch_ids.length > 0) {
      const { data: branchRows, error: branchError } = await db
        .from("client_branches")
        .select("customer_id")
        .eq("list_data_id", target.user_company)
        .in("customer_id", body.branch_ids);
      if (branchError) return jsonResponse({ status: "fail", message: branchError.message }, 500);
      if ((branchRows ?? []).length !== body.branch_ids.length) {
        return jsonResponse({ status: "fail", message: "One or more branches do not belong to this company" }, 400);
      }
    }

    const newEmail = body.email?.trim();
    if (newEmail && newEmail !== target.email) {
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(targetUserId, { email: newEmail });
      if (authUpdateError) return jsonResponse({ status: "fail", message: authUpdateError.message }, 400);
    }

    const newPassword = body.password?.trim();
    if (newPassword) {
      if (newPassword.length < 6) return jsonResponse({ status: "fail", message: "Password must be at least 6 characters" }, 400);
      const { error: passwordUpdateError } = await supabaseAdmin.auth.admin.updateUserById(targetUserId, { password: newPassword });
      if (passwordUpdateError) return jsonResponse({ status: "fail", message: passwordUpdateError.message }, 400);
    }

    const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
    if (body.user_name?.trim()) updates.user_name = body.user_name.trim();
    if (newEmail) updates.email = newEmail;

    const { error: updateError } = await db.from("user_data").update(updates).eq("user_id", targetUserId);
    if (updateError) return jsonResponse({ status: "fail", message: updateError.message }, 500);

    if (body.branch_ids) {
      await db.from("internal_user_branches").delete().eq("user_id", targetUserId);
      if (body.branch_ids.length > 0) {
        await db.from("internal_user_branches").insert(
          body.branch_ids.map((branch_id) => ({ user_id: targetUserId, branch_id, created_by: callerAuth.user.id }))
        );
      }
    }

    return jsonResponse({ status: "success" });
  } catch (error) {
    return jsonResponse({ status: "error", message: error.message }, 500);
  }
});
