// supabase/functions/create_client_user/index.ts
//
// Creates a client-side login for a workshop: either a WORKSHOP USER, who sees every branch of the
// workshop including ones added later, or a BRANCH MANAGER, who sees their own branches and has the
// orders raised there assigned to them. A user can be both — the two are independent, which is what
// lets one workshop have a different manager per branch without any of them owning the whole thing.
//
// Qparts Admin only (user_type 185, user_role 172). Creating an auth account needs the service role,
// which is why this is an edge function and not an RPC; everything after the account exists is done
// through admin_set_user_scope so the scoping rules live in one place.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CLIENT_USER_TYPE = 183;
const ROLE_CLIENT_ADMIN = 170;    // workshop user
const ROLE_BRANCH_MANAGER = 195;  // branch manager

type Body = {
  email: string;
  password: string;
  user_name: string;
  workshop_id: number;
  /** Branches this user manages: orders raised there are assigned to them. */
  manager_branch_ids?: number[];
  /** Branches they may see without managing. Ignored when they are a workshop user. */
  branch_ids?: number[];
  /** true → sees the whole workshop; false → only the branches listed above. */
  is_workshop_user?: boolean;
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

    if (!caller || caller.user_type !== 185 || caller.user_role !== 172) {
      return json({ status: "fail", message: "Access denied: Qparts Admin only" }, 403);
    }

    const body = (await req.json()) as Body;
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "").trim();
    const userName = String(body.user_name || "").trim();
    const workshopId = Number(body.workshop_id);
    const isWorkshopUser = body.is_workshop_user === true;
    const managerBranchIds = Array.isArray(body.manager_branch_ids) ? body.manager_branch_ids.map(Number) : [];
    const plainBranchIds = Array.isArray(body.branch_ids) ? body.branch_ids.map(Number) : [];

    if (!email || !password || !userName || !workshopId) {
      return json({ status: "fail", message: "email, password, user_name and workshop_id are required" }, 400);
    }
    if (password.length < 6) {
      return json({ status: "fail", message: "Password must be at least 6 characters" }, 400);
    }
    if (!isWorkshopUser && managerBranchIds.length === 0 && plainBranchIds.length === 0) {
      return json({
        status: "fail",
        message: "A user who is not a workshop user needs at least one branch",
      }, 400);
    }

    // The workshop decides the company; nothing is taken from the caller.
    const { data: workshop } = await admin
      .schema("qvm_new_apps")
      .from("client_workshops")
      .select("workshop_id, company_id")
      .eq("workshop_id", workshopId)
      .maybeSingle();
    if (!workshop) return json({ status: "fail", message: "Workshop not found" }, 404);

    // Every branch named must belong to that workshop — a stale id from the browser must not be
    // able to hand someone a branch in another company.
    const named = [...new Set([...managerBranchIds, ...plainBranchIds])];
    if (named.length > 0) {
      const { data: branches } = await admin
        .schema("qvm_new_apps")
        .from("client_branches")
        .select("customer_id")
        .eq("workshop_id", workshopId)
        .in("customer_id", named);
      if ((branches ?? []).length !== named.length) {
        return json({ status: "fail", message: "One or more branches do not belong to this workshop" }, 400);
      }
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { user_name: userName },
    });
    if (createError || !created?.user) {
      return json({ status: "fail", message: createError?.message || "Could not create the login" }, 400);
    }
    const newUserId = created.user.id;

    const { error: profileError } = await admin
      .schema("qvm_new_apps")
      .from("user_data")
      .insert({
        user_id: newUserId,
        user_name: userName,
        email,
        user_type: CLIENT_USER_TYPE,
        user_role: isWorkshopUser ? ROLE_CLIENT_ADMIN : ROLE_BRANCH_MANAGER,
        user_company: workshop.company_id,
      });
    if (profileError) {
      // Leaving an auth account with no profile behind would be a login that resolves to nothing.
      await admin.auth.admin.deleteUser(newUserId);
      return json({ status: "fail", message: profileError.message }, 500);
    }

    // Scope goes through the same RPC the admin screen uses for existing users, so there is one
    // implementation of "what this user can see" rather than two that drift.
    const branchPayload = [
      ...managerBranchIds.map((id) => ({ customer_id: id, is_manager: true })),
      ...plainBranchIds.filter((id) => !managerBranchIds.includes(id)).map((id) => ({ customer_id: id, is_manager: false })),
    ];

    const { data: scopeResult, error: scopeError } = await admin.rpc("admin_set_user_scope", {
      p_user_id: newUserId,
      p_workshop_ids: isWorkshopUser ? [workshopId] : [],
      p_branches: branchPayload,
    });
    if (scopeError) {
      return json({
        status: "fail",
        message: `The login was created but its access could not be set: ${scopeError.message}`,
        user_id: newUserId,
      }, 500);
    }

    return json({
      status: "success",
      user_id: newUserId,
      scope: scopeResult,
      message: isWorkshopUser
        ? "Workshop user created"
        : `Branch manager created for ${branchPayload.length} branch(es)`,
    });
  } catch (err) {
    console.error("create_client_user error:", err);
    return json({ status: "error", message: String(err) }, 500);
  }
});
