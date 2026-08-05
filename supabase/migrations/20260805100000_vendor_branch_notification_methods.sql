-- The RFQ/PO webhook's notification_method was reading a company-wide setting managed by
-- internal staff (get_vendor_notification_channels, added 20260718100000), not the per-vendor-user
-- self-service preference vendors set for themselves from the vendor dashboard's Branches & Users
-- page (user_data.notification_method). This resolves the actual channel(s) to notify from that
-- self-service preference instead, scoped to whichever vendor branch the RFQ/PO is being sent to
-- — mirrors get_vendor_emails' shape (Vendor Admin's own preference always included, regular users
-- filtered by branch membership when a branch is given).
CREATE FUNCTION qvm_new_apps.get_vendor_branch_notification_methods(p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL::bigint)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result text[];
BEGIN
  SELECT array_agg(DISTINCT method) INTO v_result
  FROM (
    SELECT COALESCE(u.notification_method, 'email') AS method
    FROM qvm_new_apps.user_data u
    JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_vendor = p_vendor_id AND ur.list_data = 'Vendor Admin'

    UNION

    SELECT COALESCE(u.notification_method, 'email') AS method
    FROM qvm_new_apps.user_data u
    WHERE u.user_vendor = p_vendor_id
      AND (
        p_vendor_branch_id IS NULL
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
          WHERE vbu.user_id = u.user_id AND vbu.vendor_branch_id = p_vendor_branch_id
        )
      )
  ) methods
  WHERE method IN ('email', 'whatsapp');

  RETURN COALESCE(v_result, ARRAY['email']);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_branch_notification_methods(integer, bigint) TO authenticated;
