// supabase/functions/update_client_user/index.ts
//
// Resets the password — and, when given, the display name — of one of an end customer's users.
// The customer's people are administered from the customer tree by a Qparts Admin or by a Company
// Admin whose company owns the customer; setting another account's password needs the service
// role, which is why this is an edge function and not an RPC. Same caller rules, same owner walk,
// as create_client_user.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const INTERNAL_USER_TYPE = 185;
const ROLE_QPARTS_ADMIN = 172;

type Body = {
  user_id: string;
  end_customer_id: number;
  password?: string;
  user_name?: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ status: "fail", message: "Not authorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: callerAuth, error: callerError } = await admin.auth.getUser(authHeader.replace("Bearer ", ""));
    if (callerError || !callerAuth.user) return json({ status: "fail", message: "Not authorized" }, 401);

    const { data: caller } = await admin
      .schema("qvm_new_apps")
      .from("user_data")
      .select("user_type, user_role")
      .eq("user_id", callerAuth.user.id)
      .maybeSingle();

    const { data: companyAdminRole } = await admin.schema("qvm_new_apps").rpc("company_admin_role_id");
    const ROLE_COMPANY_ADMIN = companyAdminRole ? Number(companyAdminRole) : null;

    const callerIsQpartsAdmin = caller?.user_type === INTERNAL_USER_TYPE && caller?.user_role === ROLE_QPARTS_ADMIN;
    const callerIsCompanyAdmin = !!caller && ROLE_COMPANY_ADMIN !== null && caller.user_role === ROLE_COMPANY_ADMIN;
    if (!callerIsQpartsAdmin && !callerIsCompanyAdmin) {
      return json({ status: "fail", message: "Access denied: administrators only" }, 403);
    }

    const body = (await req.json()) as Body;
    const targetUserId = String(body.user_id || "").trim();
    const endCustomerId = body.end_customer_id ? Number(body.end_customer_id) : null;
    const password = body.password == null ? null : String(body.password).trim();
    const userName = body.user_name == null ? null : String(body.user_name).trim();

    if (!targetUserId || !endCustomerId) {
      return json({ status: "fail", message: "user_id and end_customer_id are required" }, 400);
    }
    if (password !== null && password.length < 6) {
      return json({ status: "fail", message: "Password must be at least 6 characters" }, 400);
    }
    if (password === null && !userName) {
      return json({ status: "fail", message: "Nothing to change" }, 400);
    }

    // The target has to be one of THIS customer's people — the customer is what the caller's right
    // is checked against, so an id from somewhere else must not ride in on it.
    const { data: membership, error: membershipError } = await admin
      .schema("qvm_new_apps")
      .from("end_customer_users")
      .select("user_id")
      .eq("user_id", targetUserId)
      .eq("end_customer_id", endCustomerId)
      .maybeSingle();
    if (membershipError) {
      return json({ status: "fail", message: `Could not read the customer's users: ${membershipError.message}` }, 500);
    }
    if (!membership) return json({ status: "fail", message: "That user does not belong to this customer" }, 404);

    // A Company Admin reaches a customer through a workshop or a vendor of one of their companies.
    if (callerIsCompanyAdmin) {
      const { data: own, error: ownError } = await admin
        .schema("qvm_new_apps").from("user_companies").select("company_id").eq("user_id", callerAuth.user.id);
      if (ownError) return json({ status: "fail", message: `Could not read your companies: ${ownError.message}` }, 500);
      const callerCompanies = (own ?? []).map((r) => Number(r.company_id));

      const { data: owners, error: ownersError } = await admin
        .schema("qvm_new_apps").from("end_customer_owners").select("workshop_id, vendor_id").eq("end_customer_id", endCustomerId);
      if (ownersError) return json({ status: "fail", message: `Could not read the customer's owners: ${ownersError.message}` }, 500);
      const workshopIds = (owners ?? []).map((o) => o.workshop_id).filter(Boolean);
      const vendorIds = (owners ?? []).map((o) => o.vendor_id).filter(Boolean);
      const reached: number[] = [];
      if (workshopIds.length) {
        const { data } = await admin.schema("qvm_new_apps").from("workshop_companies").select("company_id").in("workshop_id", workshopIds);
        reached.push(...(data ?? []).map((r) => Number(r.company_id)));
      }
      if (vendorIds.length) {
        const { data } = await admin.schema("qvm_new_apps").from("vendor_companies").select("company_id").in("vendor_id", vendorIds);
        reached.push(...(data ?? []).map((r) => Number(r.company_id)));
      }
      if (!reached.some((c) => callerCompanies.includes(c))) {
        return json({ status: "fail", message: "Access denied: this customer is not yours to administer" }, 403);
      }
    }

    if (password !== null) {
      const { error: pwError } = await admin.auth.admin.updateUserById(targetUserId, { password });
      if (pwError) return json({ status: "fail", message: pwError.message }, 400);
    }
    if (userName) {
      const { error: nameError } = await admin
        .schema("qvm_new_apps").from("user_data").update({ user_name: userName }).eq("user_id", targetUserId);
      if (nameError) return json({ status: "fail", message: nameError.message }, 400);
      await admin.auth.admin.updateUserById(targetUserId, { user_metadata: { user_name: userName } });
    }

    return json({ status: "success", user_id: targetUserId });
  } catch (e) {
    return json({ status: "fail", message: (e as Error).message || "Unexpected error" }, 500);
  }
});
