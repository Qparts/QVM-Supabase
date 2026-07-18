-- The LIMIT in the previous version sat on the outer aggregate query (which always returns exactly
-- one row, the jsonb_agg result), so it never actually capped how many rows fed into the array —
-- all 611 vendor/user rows were returned on every call. Move the LIMIT onto the unioned row set
-- itself, before aggregation, so an empty search is capped like the old vendor-company list was.
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

  SELECT COALESCE(jsonb_agg(entry), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT entry, vendor_name, sort_name
    FROM (
      SELECT
        jsonb_build_object(
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
        ) AS entry,
        v.vendor_name,
        u.user_name AS sort_name
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

      UNION ALL

      SELECT
        jsonb_build_object(
          'user_id', 'company:' || v.vendor_id,
          'user_name', v.vendor_name,
          'email', v.email,
          'vendor_id', v.vendor_id,
          'vendor_name', v.vendor_name,
          'user_role', NULL,
          'branches', '[]'::jsonb
        ) AS entry,
        v.vendor_name,
        v.vendor_name AS sort_name
      FROM qvm_new_apps.vendors v
      WHERE NOT EXISTS (
        SELECT 1 FROM qvm_new_apps.user_data u2 WHERE u2.user_vendor = v.vendor_id AND u2.user_type = 205
      )
      AND (p_search IS NULL OR p_search = '' OR v.vendor_name ILIKE '%'||p_search||'%')
    ) combined
    ORDER BY vendor_name, sort_name
    LIMIT 100
  ) limited;

  RETURN v_result;
END;
$function$;
