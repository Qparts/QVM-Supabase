-- The "Send RFQ to Vendors" modal listed vendor USER logins (search_vendor_users_for_rfq) —
-- the same vendor company appeared once per login it had, and picking a specific login further
-- scoped the branch picker to just that user's own assigned branches. Replaces it with a plain
-- company-level search: one row per vendor, matched by company name only, with the branch picker
-- always showing every one of that company's branches (never scoped to a specific user).
CREATE FUNCTION qvm_new_apps.search_vendors_for_rfq(p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_result jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = auth.uid()
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'vendor_id', v.vendor_id,
           'vendor_name', v.vendor_name,
           'email', v.email
         ) ORDER BY v.vendor_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendors v
  WHERE p_search IS NULL OR p_search = '' OR v.vendor_name ILIKE '%'||p_search||'%'
  LIMIT 100;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.search_vendors_for_rfq(text) TO authenticated;

-- No more callers of the per-login search.
DROP FUNCTION IF EXISTS qvm_new_apps.search_vendor_users_for_rfq(text);
