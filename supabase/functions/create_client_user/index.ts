// supabase/functions/create_client_user/index.ts
//
// Creates a client-side login for a workshop: either a WORKSHOP USER, who sees every branch of the
// workshop including ones added later, or a BRANCH MANAGER, who sees their own branches and has the
// orders raised there assigned to them. A user can be both — the two are independent, which is what
// lets one workshop have a different manager per branch without any of them owning the whole thing.
//
// It also creates the two internal accounts: a COMPANY USER, who sees every branch of every workshop
// serving one company, and a COMPANY ADMIN, who additionally runs that company — its workshops,
// branches, managers and users.
//
// Qparts Admin, or a Company Admin acting inside their own company. Creating an auth account needs
// the service role, which is why this is an edge function and not an RPC; everything after the
// account exists is done through admin_set_user_scope so the scoping rules live in one place.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CLIENT_USER_TYPE = 183;
const INTERNAL_USER_TYPE = 185;
const ROLE_CLIENT_ADMIN = 170;          // workshop user
const ROLE_BRANCH_MANAGER = 195;        // branch manager
const ROLE_INTERNAL_BRANCH_USER = 271;  // company user: the whole menu, narrowed data
const ROLE_QPARTS_ADMIN = 172;

type Body = {
  email: string;
  password: string;
  user_name: string;
  /** Either of these decides what kind of account this is. */
  workshop_id?: number;
  /**
   * A company-level user: internal, seeing every branch of every workshop that serves this
   * company — including workshops that join later, which is the reason this exists rather than
   * ticking branches by hand.
   */
  company_id?: number;
  /** Branches this user manages: orders raised there are assigned to them. */
  manager_branch_ids?: number[];
  /** Branches they may see without managing. Ignored when they are a workshop user. */
  branch_ids?: number[];
  /** true → sees the whole workshop; false → only the branches listed above. */
  is_workshop_user?: boolean;
  /**
   * Company mode only: make this account a Company Admin rather than a plain company user — it runs
   * the company's tree as well as reading its data.
   */
  is_company_admin?: boolean;
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

    // The Company Admin role is minted per environment, so it is resolved by name rather than
    // written here as a number that would be right on one branch and wrong on the next.
    const { data: companyAdminRole } = await admin
      .schema("qvm_new_apps")
      .rpc("company_admin_role_id");
    const ROLE_COMPANY_ADMIN = companyAdminRole ? Number(companyAdminRole) : null;

    const callerIsQpartsAdmin = caller?.user_type === INTERNAL_USER_TYPE && caller?.user_role === ROLE_QPARTS_ADMIN;
    const callerIsCompanyAdmin = !!caller && ROLE_COMPANY_ADMIN !== null && caller.user_role === ROLE_COMPANY_ADMIN;

    if (!callerIsQpartsAdmin && !callerIsCompanyAdmin) {
      return json({ status: "fail", message: "Access denied: Qparts Admin only" }, 403);
    }

    /** The companies a Company Admin runs. Empty for a Qparts Admin, who is never checked against it. */
    let callerCompanies: number[] = [];
    if (callerIsCompanyAdmin) {
      const { data: own, error: ownError } = await admin
        .schema("qvm_new_apps")
        .from("user_companies")
        .select("company_id")
        .eq("user_id", callerAuth.user.id);
      if (ownError) {
        return json({ status: "fail", message: `Could not read your companies: ${ownError.message}` }, 500);
      }
      callerCompanies = (own ?? []).map((r) => Number(r.company_id));
      if (callerCompanies.length === 0) {
        return json({ status: "fail", message: "Access denied: your account has no company" }, 403);
      }
    }

    const body = (await req.json()) as Body;
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "").trim();
    const userName = String(body.user_name || "").trim();
    const workshopId = body.workshop_id ? Number(body.workshop_id) : null;
    const companyId = body.company_id ? Number(body.company_id) : null;
    const isWorkshopUser = body.is_workshop_user === true;
    const wantsCompanyAdmin = body.is_company_admin === true;
    const managerBranchIds = Array.isArray(body.manager_branch_ids) ? body.manager_branch_ids.map(Number) : [];
    const plainBranchIds = Array.isArray(body.branch_ids) ? body.branch_ids.map(Number) : [];

    if (!email || !password || !userName) {
      return json({ status: "fail", message: "email, password and user_name are required" }, 400);
    }
    if (!workshopId && !companyId) {
      return json({ status: "fail", message: "Either workshop_id or company_id is required" }, 400);
    }
    if (workshopId && companyId) {
      return json({
        status: "fail",
        message: "Give a workshop or a company, not both — they are different kinds of account",
      }, 400);
    }
    if (wantsCompanyAdmin && !companyId) {
      return json({
        status: "fail",
        message: "A Company Admin belongs to a company — give company_id, not workshop_id",
      }, 400);
    }
    if (wantsCompanyAdmin && ROLE_COMPANY_ADMIN === null) {
      return json({ status: "fail", message: "The Company Admin role is missing from this environment" }, 500);
    }
    if (password.length < 6) {
      return json({ status: "fail", message: "Password must be at least 6 characters" }, 400);
    }
    if (workshopId && !isWorkshopUser && managerBranchIds.length === 0 && plainBranchIds.length === 0) {
      return json({
        status: "fail",
        message: "A user who is not a workshop user needs at least one branch",
      }, 400);
    }

    // ---------------------------------------------------------------- company-level user
    if (companyId) {
      if (callerIsCompanyAdmin && !callerCompanies.includes(companyId)) {
        return json({ status: "fail", message: "Access denied: this company is not yours to administer" }, 403);
      }

      const { data: company, error: companyError } = await admin
        .schema("qvm_new_apps")
        .from("client_companies")
        .select("company_id")
        .eq("company_id", companyId)
        .maybeSingle();
      if (companyError) {
        return json({ status: "fail", message: `Could not read the company: ${companyError.message}` }, 500);
      }
      if (!company) return json({ status: "fail", message: `Company ${companyId} not found` }, 404);

      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email, password, email_confirm: true, user_metadata: { user_name: userName },
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
          user_type: INTERNAL_USER_TYPE,
          user_role: wantsCompanyAdmin ? ROLE_COMPANY_ADMIN : ROLE_INTERNAL_BRANCH_USER,
          user_company: companyId,
        });
      if (profileError) {
        await admin.auth.admin.deleteUser(newUserId);
        return json({ status: "fail", message: profileError.message }, 500);
      }

      const { data: scopeResult, error: scopeError } = await admin.rpc("admin_set_user_scope", {
        p_user_id: newUserId,
        p_company_ids: [companyId],
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
        message: wantsCompanyAdmin
          ? "Company Admin created — runs this company and sees every branch of it"
          : "Company user created — sees every branch of this company",
      });
    }

    // The workshop decides the company; nothing is taken from the caller.
    const { data: workshop, error: workshopError } = await admin
      .schema("qvm_new_apps")
      .from("client_workshops")
      .select("workshop_id, company_id")
      .eq("workshop_id", workshopId)
      .maybeSingle();
    // Ignoring the error here once cost an afternoon: a missing grant on the table came back as
    // "Workshop not found" for a workshop that plainly existed. A query that FAILED and a query
    // that found nothing are different answers and must read differently.
    if (workshopError) {
      return json({ status: "fail", message: `Could not read the workshop: ${workshopError.message}` }, 500);
    }
    if (!workshop) return json({ status: "fail", message: `Workshop ${workshopId} not found` }, 404);

    // A workshop serves any number of companies; a Company Admin may staff it if one of them is
    // theirs. The workshop's own company_id is checked too — it is set for a workshop that has not
    // been through the many-to-many assignment yet.
    if (callerIsCompanyAdmin) {
      const { data: served, error: servedError } = await admin
        .schema("qvm_new_apps")
        .from("workshop_companies")
        .select("company_id")
        .eq("workshop_id", workshopId);
      if (servedError) {
        return json({ status: "fail", message: `Could not read the workshop's companies: ${servedError.message}` }, 500);
      }
      const companiesServed = new Set([
        ...(served ?? []).map((r) => Number(r.company_id)),
        ...(workshop.company_id ? [Number(workshop.company_id)] : []),
      ]);
      if (!callerCompanies.some((c) => companiesServed.has(c))) {
        return json({ status: "fail", message: "Access denied: this workshop is not yours to administer" }, 403);
      }
    }

    // Every branch named must belong to that workshop — a stale id from the browser must not be
    // able to hand someone a branch in another company.
    const named = [...new Set([...managerBranchIds, ...plainBranchIds])];
    if (named.length > 0) {
      const { data: branches, error: branchError } = await admin
        .schema("qvm_new_apps")
        .from("client_branches")
        .select("customer_id")
        .eq("workshop_id", workshopId)
        .in("customer_id", named);
      if (branchError) {
        return json({ status: "fail", message: `Could not read the branches: ${branchError.message}` }, 500);
      }
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
