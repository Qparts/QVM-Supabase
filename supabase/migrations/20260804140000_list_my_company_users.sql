-- Populates the "send to a specific user" picker in the notification composer — every user
-- sharing the caller's own user_company, matching exactly who send_notification_to_user is
-- allowed to target.
CREATE FUNCTION qvm_new_apps.list_my_company_users()
 RETURNS TABLE(user_id uuid, user_name text)
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
  SELECT ud.user_id, ud.user_name
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_company = v_company_id
  ORDER BY ud.user_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_my_company_users() TO authenticated;
