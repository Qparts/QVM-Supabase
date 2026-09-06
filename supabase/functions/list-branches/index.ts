// supabase/functions/list-branches/index.ts
// Lists the database branches of a Supabase project (QVM/dev, QVM/test, …) with the git branch each
// one tracks and the state of its last deploy.
//
// Branches are not visible from the database — they are an account-level concept — so this reads the
// Management API rather than SQL. That needs a personal access token, which is NOT one of the
// secrets an edge function gets for free:
//
//   supabase secrets set SUPABASE_MANAGEMENT_TOKEN=sbp_xxx --project-ref <ref>
//
// Scope it carefully: a management token can act on every project in the account, so this function
// deliberately refuses to run for anyone who is not a signed-in internal user.
//
// GET /functions/v1/list-branches                      -> branches of DEFAULT_PARENT_REF
// GET /functions/v1/list-branches?project_ref=abc123   -> branches of that project
//
// The parent project owns the branches: asking a branch for its own branches returns nothing, so
// point this at the production project.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const MANAGEMENT_API = "https://api.supabase.com/v1";
const DEFAULT_PARENT_REF = Deno.env.get("SUPABASE_PARENT_PROJECT_REF") ?? "iqdmyvrrtcmvwupqinqq";
const REQUEST_TIMEOUT_MS = 15000;

/** user_type 185 is the internal-staff marker used across qvm_new_apps. */
const INTERNAL_USER_TYPE = 185;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * The Management API has added fields over time, so the shape is normalised to what a caller
 * actually needs and the untouched payload is returned alongside it.
 */
function normalise(b: Record<string, unknown>) {
  return {
    id: b.id ?? null,
    name: b.name ?? null,
    project_ref: b.project_ref ?? null,
    parent_project_ref: b.parent_project_ref ?? null,
    git_branch: b.git_branch ?? null,
    is_default: Boolean(b.is_default),
    persistent: Boolean(b.persistent),
    status: b.status ?? null,
    pr_number: b.pr_number ?? null,
    created_at: b.created_at ?? null,
    updated_at: b.updated_at ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const token = Deno.env.get("SUPABASE_MANAGEMENT_TOKEN");
    if (!token) {
      return json({
        status: "fail",
        message:
          "SUPABASE_MANAGEMENT_TOKEN is not set. Add it with: " +
          "supabase secrets set SUPABASE_MANAGEMENT_TOKEN=sbp_xxx",
      }, 500);
    }

    // Caller must be a signed-in internal user — this function borrows a token that can reach every
    // project in the account, so it is not something to leave open.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ status: "fail", message: "Not authorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: auth, error: authError } = await admin.auth.getUser(
      authHeader.replace(/^Bearer\s+/i, ""),
    );
    if (authError || !auth?.user?.id) {
      return json({ status: "fail", message: "Not authorized" }, 401);
    }

    const { data: profile } = await admin
      .schema("qvm_new_apps")
      .from("user_data")
      .select("user_type")
      .eq("user_id", auth.user.id)
      .maybeSingle();

    if (profile?.user_type !== INTERNAL_USER_TYPE) {
      return json({ status: "fail", message: "Internal users only" }, 403);
    }

    const url = new URL(req.url);
    const parentRef = url.searchParams.get("project_ref") || DEFAULT_PARENT_REF;

    const res = await fetch(`${MANAGEMENT_API}/projects/${parentRef}/branches`, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });

    const text = await res.text();
    if (!res.ok) {
      // Two failures are worth naming, because they look identical from the client otherwise.
      const hint =
        res.status === 401 || res.status === 403
          ? "The management token was rejected — it may be expired or lack access to this project."
          : res.status === 404
          ? `Project ${parentRef} has no branches, or is itself a branch. Point project_ref at the parent project.`
          : "";
      return json({ status: "fail", message: `Management API ${res.status}: ${text}`, hint }, 502);
    }

    let payload: unknown;
    try {
      payload = JSON.parse(text);
    } catch {
      return json({ status: "fail", message: "Management API returned a non-JSON body", body: text }, 502);
    }

    const list = Array.isArray(payload) ? payload : [];
    const branches = list.map((b) => normalise(b as Record<string, unknown>));

    return json({
      status: "success",
      parent_project_ref: parentRef,
      count: branches.length,
      branches,
      raw: payload,
    });
  } catch (err) {
    console.error("list-branches error:", err);
    return json({ status: "error", message: String(err) }, 500);
  }
});
