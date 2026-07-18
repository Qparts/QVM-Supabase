-- Synced from QVM/test branch applied migration history (version 20260707215642, name: vendor_preferred_branch_for_all_vendor_users)
CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_preferred_branch(p_vendor_id integer, p_vendor_branch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_is_admin boolean;
  v_belongs_to_vendor boolean;
  v_assigned_to_branch boolean;
BEGIN
  v_is_admin := qvm_new_apps.is_vendor_admin_for(p_vendor_id);

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    WHERE u.user_id = auth.uid() AND u.user_vendor = p_vendor_id
  ) INTO v_belongs_to_vendor;

  IF NOT v_is_admin AND NOT v_belongs_to_vendor THEN
    RETURN jsonb_build_object('status', false, 'message', 'Not authorized');
  END IF;

  IF p_vendor_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM qvm_new_apps.vendor_branches
      WHERE vendor_branch_id = p_vendor_branch_id AND vendor_id = p_vendor_id
    ) THEN
      RETURN jsonb_build_object('status', false, 'message', 'Branch does not belong to this vendor');
    END IF;

    IF NOT v_is_admin THEN
      SELECT EXISTS (
        SELECT 1 FROM qvm_new_apps.vendor_branch_users
        WHERE user_id = auth.uid() AND vendor_branch_id = p_vendor_branch_id
      ) INTO v_assigned_to_branch;
      IF NOT v_assigned_to_branch THEN
        RETURN jsonb_build_object('status', false, 'message', 'You are not assigned to this branch');
      END IF;
    END IF;
  END IF;

  UPDATE qvm_new_apps.vendors
  SET preferred_branch_id = p_vendor_branch_id
  WHERE vendor_id = p_vendor_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_user_data(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  result jsonb;
  v_vendor_admin_role_id integer;
BEGIN
  SELECT ld.list_data_id INTO v_vendor_admin_role_id
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
  WHERE l.list_name = 'user_role' AND ld.list_data = 'Vendor Admin';

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
           'user_branch_id', u.user_branch,
           'user_vendor_id', u.user_vendor,
           'is_vendor_admin', (u.user_role IS NOT NULL AND u.user_role = v_vendor_admin_role_id),
           'preferred_branch_id', pv.preferred_branch_id,
           'vendor_branches', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'vendor_branch_id', vb.vendor_branch_id,
                      'branch_name', vb.branch_name,
                      'city', vb.city
                    ) ORDER BY vb.city, vb.branch_name)
             FROM qvm_new_apps.vendor_branch_users vbu
             JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
             WHERE vbu.user_id = u.user_id
           ), '[]'::jsonb)
         )
  INTO result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON u.user_role = ur.list_data_id
  LEFT JOIN qvm_new_apps.list_data ut ON u.user_type = ut.list_data_id
  LEFT JOIN qvm_new_apps.list_data uc ON u.user_company = uc.list_data_id
  LEFT JOIN qvm_new_apps.client_branches cb ON u.user_branch = cb.customer_id
  LEFT JOIN qvm_new_apps.vendors pv ON pv.vendor_id = u.user_vendor
  WHERE u.user_id = p_user_id;

  RETURN result;
END;
$function$;
;
