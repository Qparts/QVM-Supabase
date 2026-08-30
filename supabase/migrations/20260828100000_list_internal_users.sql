-- Backs the new "Internal Users" management page: every user_type=185 account sharing the
-- caller's own user_company, with their role name and assigned branches (via
-- internal_user_branches). Same scoping precedent as list_my_company_users.
CREATE FUNCTION qvm_new_apps.list_internal_users()
 RETURNS TABLE(
   user_id uuid,
   user_name text,
   email text,
   user_role_id integer,
   user_role_name text,
   branch_ids integer[],
   branch_names text[]
 )
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT ud.user_company INTO v_company_id FROM qvm_new_apps.user_data ud WHERE ud.user_id = auth.uid();
  IF v_company_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ud.user_id,
    ud.user_name,
    ud.email,
    ud.user_role,
    ur.list_data AS user_role_name,
    COALESCE(array_agg(iub.branch_id) FILTER (WHERE iub.branch_id IS NOT NULL), ARRAY[]::integer[]) AS branch_ids,
    COALESCE(array_agg(cb.branch_name) FILTER (WHERE cb.branch_name IS NOT NULL), ARRAY[]::text[]) AS branch_names
  FROM qvm_new_apps.user_data ud
  LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = ud.user_role
  LEFT JOIN qvm_new_apps.internal_user_branches iub ON iub.user_id = ud.user_id
  LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = iub.branch_id
  WHERE ud.user_company = v_company_id AND ud.user_type = 185
  GROUP BY ud.user_id, ud.user_name, ud.email, ud.user_role, ur.list_data
  ORDER BY ud.user_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_internal_users() TO authenticated;
