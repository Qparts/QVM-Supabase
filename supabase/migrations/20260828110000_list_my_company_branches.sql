-- Backs the "Internal Users" page's branch-assignment picker: the caller's own company's
-- client_branches rows (customer_id / branch_name), i.e. exactly the id space
-- internal_user_branches.branch_id references — distinct from the generic list_data 'branch'
-- list that get_list_data_json('branch') returns.
CREATE FUNCTION qvm_new_apps.list_my_company_branches()
 RETURNS TABLE(branch_id integer, branch_name text)
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
  SELECT cb.customer_id, cb.branch_name
  FROM qvm_new_apps.client_branches cb
  WHERE cb.list_data_id = v_company_id
  ORDER BY cb.branch_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_my_company_branches() TO authenticated;
