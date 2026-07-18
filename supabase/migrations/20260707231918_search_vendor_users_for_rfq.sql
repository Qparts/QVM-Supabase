-- Synced from QVM/test branch applied migration history (version 20260707231918, name: search_vendor_users_for_rfq)
CREATE OR REPLACE FUNCTION qvm_new_apps.search_vendor_users_for_rfq(p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', u.user_id,
           'user_name', u.user_name,
           'email', u.email,
           'vendor_id', u.user_vendor,
           'vendor_name', v.vendor_name,
           'user_role', ur.list_data,
           'branches', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'vendor_branch_id', vb.vendor_branch_id,
                      'branch_name', vb.branch_name,
                      'city', vb.city
                    ) ORDER BY vb.city, vb.branch_name)
             FROM qvm_new_apps.vendor_branch_users vbu
             JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
             WHERE vbu.user_id = u.user_id
           ), '[]'::jsonb)
         ) ORDER BY v.vendor_name, u.user_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.user_data u
  JOIN qvm_new_apps.vendors v ON v.vendor_id = u.user_vendor
  LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
  WHERE u.user_type = 205
    AND (
      p_search IS NULL OR p_search = '' OR
      u.user_name ILIKE '%'||p_search||'%' OR
      u.email ILIKE '%'||p_search||'%' OR
      v.vendor_name ILIKE '%'||p_search||'%'
    )
  LIMIT 50;

  RETURN v_result;
END;
$function$;
;
