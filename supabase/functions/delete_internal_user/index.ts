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
      .select("user_id, user_type, user_role, user_company")
      .eq("user_id", targetUserId)
      .maybeSingle();
    if (targetError) return jsonResponse({ status: "fail", message: targetError.message }, 500);
    if (!target || target.user_type !== 185) return jsonResponse({ status: "fail", message: "Internal user not found" }, 404);

    const { data: callerData, error: callerDataError } = await db
      .from("user_data")
      .select("user_type, user_role, user_company")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();
    if (callerDataError) return jsonResponse({ status: "fail", message: callerDataError.message }, 500);

    const { data: roleRows } = await db
      .from("list_data")
      .select("list_data_id, list_data, lists!inner(list_name)")
      .eq("lists.list_name", "user_role")
      .eq("list_data", "Qparts Admin");
    const qpartsAdminRoleId = (roleRows ?? []).find((r: any) => r.list_data === "Qparts Admin")?.list_data_id;

    // Only Qparts Admin accounts may delete internal sub-users.
    const isInternal = callerData?.user_type === 185;
    const isQpartsAdmin = qpartsAdminRoleId != null && callerData?.user_role === qpartsAdminRoleId;
    const sameCompany = callerData?.user_company != null && callerData.user_company === target.user_company;
    if (!isInternal || !isQpartsAdmin || !sameCompany) return jsonResponse({ status: "fail", message: "Not authorized: Qparts Admin only" }, 403);

    // Qparts Admin accounts can never be deleted from this page, regardless of how many exist.
    if (qpartsAdminRoleId && target.user_role === qpartsAdminRoleId) {
      return jsonResponse({ status: "fail", message: "Qparts Admin accounts cannot be deleted" }, 400);
    }

    const { error: deleteBranchesError } = await db.from("internal_user_branches").delete().eq("user_id", targetUserId);
    if (deleteBranchesError) return jsonResponse({ status: "fail", message: deleteBranchesError.message }, 500);

    // user_data is never hard-deleted: dozens of tables (status_logs, pricing_logs, cost_logs,
    // quotations.account_manager/service_advisor, purchase_orders.uploaded_by, notes, etc.)
    // reference user_data(user_id) with NO ACTION for audit-trail purposes, so a hard delete fails
    // the moment the user has any history. user_data.user_id has no FK to auth.users, so deleting
    // only the auth account already fully revokes login/access; deleted_at just hides them from the
    // Internal Users list while preserving every historical reference.
    //
    // user_data's primary key is actually `email` (not user_id) — tombstone it here so the original
    // address is freed up for a brand new account. Confirmed live: recreating a user with a
    // previously-deleted email failed with "duplicate key value violates unique constraint
    // user_data_pkey" because the old (undeleted) email still occupied the PK.
    const tombstonedEmail = `deleted+${targetUserId}+${target.email}`;
    const { error: softDeleteError } = await db
      .from("user_data")
      .update({ deleted_at: new Date().toISOString(), email: tombstonedEmail })
      .eq("user_id", targetUserId);
    if (softDeleteError) return jsonResponse({ status: "fail", message: softDeleteError.message }, 500);

    const { error: deleteAuthError } = await supabaseAdmin.auth.admin.deleteUser(targetUserId);
    if (deleteAuthError) return jsonResponse({ status: "fail", message: deleteAuthError.message }, 500);

    return jsonResponse({ status: "success" });
  } catch (error) {
    return jsonResponse({ status: "error", message: error.message }, 500);
  }
});
