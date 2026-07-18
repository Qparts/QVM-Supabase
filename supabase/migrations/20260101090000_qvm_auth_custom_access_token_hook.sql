CREATE OR REPLACE FUNCTION qvm_new_apps.get_user_data(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
           'user_id', u.user_id,
           'email', u.email,
           'user_name', u.user_name,
           'user_role', ur.list_data,
           'user_role_id', u.user_role,
           'user_type', ut.list_data,
           'user_type_id', u.user_type,
           'user_company', uc.list_data,
           'user_company_id', u.user_company,
           'user_branch', cb.branch_name,
           'user_branch_id', u.user_branch
         )
  INTO result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON u.user_role = ur.list_data_id
  LEFT JOIN qvm_new_apps.list_data ut ON u.user_type = ut.list_data_id
  LEFT JOIN qvm_new_apps.list_data uc ON u.user_company = uc.list_data_id
  LEFT JOIN qvm_new_apps.client_branches cb ON u.user_branch = cb.customer_id
  WHERE u.user_id = p_user_id;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  claims jsonb;
  user_data jsonb;
BEGIN
  claims := event->'claims';
  user_data := qvm_new_apps.get_user_data((event->>'user_id')::uuid);

  IF user_data IS NULL THEN
    claims := jsonb_set(claims, '{user_data}', 'null'::jsonb, true);
  ELSE
    claims := jsonb_set(claims, '{user_data}', user_data, true);
  END IF;

  event := jsonb_set(event, '{claims}', claims, true);
  RETURN event;
END;
$function$;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated, anon, public;

GRANT USAGE ON SCHEMA qvm_new_apps TO supabase_auth_admin;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_user_data(uuid) TO supabase_auth_admin;
GRANT SELECT ON TABLE qvm_new_apps.user_data TO supabase_auth_admin;
GRANT SELECT ON TABLE qvm_new_apps.list_data TO supabase_auth_admin;
GRANT SELECT ON TABLE qvm_new_apps.client_branches TO supabase_auth_admin;

DROP POLICY IF EXISTS "Auth admin can read user_data" ON qvm_new_apps.user_data;
CREATE POLICY "Auth admin can read user_data" ON qvm_new_apps.user_data
AS PERMISSIVE FOR SELECT
TO supabase_auth_admin
USING (true);

DROP POLICY IF EXISTS "Auth admin can read list_data" ON qvm_new_apps.list_data;
CREATE POLICY "Auth admin can read list_data" ON qvm_new_apps.list_data
AS PERMISSIVE FOR SELECT
TO supabase_auth_admin
USING (true);

DROP POLICY IF EXISTS "Auth admin can read client_branches" ON qvm_new_apps.client_branches;
CREATE POLICY "Auth admin can read client_branches" ON qvm_new_apps.client_branches
AS PERMISSIVE FOR SELECT
TO supabase_auth_admin
USING (true);
