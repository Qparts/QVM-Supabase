import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type UserData = {
  email: string | null;
  user_name: string | null;
  user_id: string | number | null;
  user_role: string | null;
  user_type: string | null;
  user_branch: string | null;
  user_company: string | null;
  user_role_id: string | number | null;
  user_type_id: string | number | null;
  user_branch_id: string | number | null;
  user_company_id: string | number | null;
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !supabaseAnonKey) {
      return new Response(JSON.stringify({ error: "Missing Supabase env vars" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const authHeader = req.headers.get("Authorization") ?? "";

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    });

    const { data: userRes, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userRes?.user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const userId = userRes.user.id;

    const db = supabase.schema("qvm_new_apps");

    const { data: raw, error: rawErr } = await db
      .from("user_data")
      .select("email,user_name,user_id,user_role,user_type,user_branch,user_company")
      .eq("user_id", userId)
      .maybeSingle();

    if (rawErr) throw rawErr;

    if (!raw) {
      return new Response(JSON.stringify({ error: "profile_not_found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const userCompanyId = raw.user_company ?? null;
    const userRoleId = raw.user_role ?? null;
    const userTypeId = raw.user_type ?? null;
    const userBranchId = raw.user_branch ?? null;

    const listDataIds = [userCompanyId, userRoleId, userTypeId].filter(
      (v): v is string | number => v !== null && v !== undefined,
    );

    const listDataMap = new Map<string, string>();
    if (listDataIds.length > 0) {
      const { data: listRows, error: listErr } = await db
        .from("list_data")
        .select("list_data_id,list_data")
        .in("list_data_id", listDataIds);

      if (listErr) throw listErr;

      for (const row of listRows ?? []) {
        if (row?.list_data_id === null || row?.list_data_id === undefined) continue;
        listDataMap.set(String(row.list_data_id), String(row.list_data ?? ""));
      }
    }

    let branchName: string | null = null;
    if (userBranchId !== null && userBranchId !== undefined) {
      const { data: branchRow, error: branchErr } = await db
        .from("client_branches")
        .select("branch_name,customer_id")
        .eq("customer_id", userBranchId)
        .maybeSingle();

      if (branchErr) throw branchErr;
      branchName = branchRow?.branch_name ?? null;
    }

    const userData: UserData = {
      email: raw.email ?? null,
      user_name: raw.user_name ?? null,
      user_id: raw.user_id ?? null,
      user_role: userRoleId === null ? null : listDataMap.get(String(userRoleId)) ?? null,
      user_type: userTypeId === null ? null : listDataMap.get(String(userTypeId)) ?? null,
      user_company: userCompanyId === null ? null : listDataMap.get(String(userCompanyId)) ?? null,
      user_branch: branchName,
      user_role_id: userRoleId,
      user_type_id: userTypeId,
      user_company_id: userCompanyId,
      user_branch_id: userBranchId,
    };

    return new Response(JSON.stringify(userData), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({
        error: "Unexpected error",
        details: err instanceof Error ? err.message : String(err),
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
