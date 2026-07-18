-- Create a public RPC that returns the authenticated user's client/branch context
-- Reads from qvm_new_apps schema and is callable from REST and supabase-js

BEGIN;

CREATE OR REPLACE FUNCTION public.get_user_profile_ctx()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_email text;
  v_user_name text;
  v_user_role_id bigint;
  v_user_type_id bigint;
  v_user_company_id bigint;
  v_user_branch_id bigint;
  v_branch_name text;
  v_client_list_id bigint;
  v_client_name text;
  v_user_role_name text;
  v_user_type_name text;
  v_user_company_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT ud.email, ud.user_name, ud.user_id, ud.user_role, ud.user_type, ud.user_company, ud.user_branch
  INTO v_email, v_user_name, v_user_id, v_user_role_id, v_user_type_id, v_user_company_id, v_user_branch_id
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found';
  END IF;

  -- Resolve branch name and the client's list_data_id from client_branches
  IF v_user_branch_id IS NOT NULL THEN
    SELECT cb.branch_name, cb.list_data_id
    INTO v_branch_name, v_client_list_id
    FROM qvm_new_apps.client_branches cb
    WHERE cb.customer_id = v_user_branch_id;
  END IF;

  -- Resolve preferred client name: from client_branches.list_data_id
  IF v_client_list_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_client_name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data_id = v_client_list_id;
  END IF;

  -- Resolve role/type/company names from list_data
  IF v_user_role_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_user_role_name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data_id = v_user_role_id;
  END IF;
  IF v_user_type_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_user_type_name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data_id = v_user_type_id;
  END IF;
  IF v_user_company_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_user_company_name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data_id = v_user_company_id;
  END IF;

  RETURN jsonb_build_object(
    'email', v_email,
    'user_name', v_user_name,
    'user_id', v_user_id,
    'user_role', v_user_role_name,
    'user_type', v_user_type_name,
    'user_company', COALESCE(v_client_name, v_user_company_name),
    'user_branch', v_branch_name,
    'user_role_id', v_user_role_id,
    'user_type_id', v_user_type_id,
    'user_company_id', COALESCE(v_client_list_id, v_user_company_id),
    'user_branch_id', v_user_branch_id
  );
END;
$$;

-- Lock down and grant execution to authenticated users
REVOKE ALL ON FUNCTION public.get_user_profile_ctx() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_profile_ctx() TO authenticated;

COMMIT;
