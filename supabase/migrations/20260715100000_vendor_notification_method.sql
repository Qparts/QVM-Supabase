-- Lets any vendor user pick how their company wants to be notified of new RFQs/POs — email or
-- WhatsApp. Mirrors the preferred_branch_id pattern (20260708100000/20260708110000): a
-- company-wide setting on `vendors`, settable by the admin-vendor or any user belonging to that
-- vendor, surfaced in the JWT-backing user_data payload so the navbar can show/toggle it, and
-- read by the RFQ/PO n8n webhook builders so n8n knows which channel to use per vendor.

ALTER TABLE qvm_new_apps.vendors
  ADD COLUMN notification_method text NOT NULL DEFAULT 'email'
  CHECK (notification_method IN ('email', 'whatsapp'));

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_notification_method(p_vendor_id integer, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_is_admin boolean;
  v_belongs_to_vendor boolean;
BEGIN
  IF p_method NOT IN ('email', 'whatsapp') THEN
    RETURN jsonb_build_object('status', false, 'message', 'Invalid notification method');
  END IF;

  v_is_admin := qvm_new_apps.is_vendor_admin_for(p_vendor_id);

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    WHERE u.user_id = auth.uid() AND u.user_vendor = p_vendor_id
  ) INTO v_belongs_to_vendor;

  IF NOT v_is_admin AND NOT v_belongs_to_vendor THEN
    RETURN jsonb_build_object('status', false, 'message', 'Not authorized');
  END IF;

  UPDATE qvm_new_apps.vendors
  SET notification_method = p_method
  WHERE vendor_id = p_vendor_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_vendor_notification_method(p_vendor_id integer, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN qvm_new_apps.set_vendor_notification_method(p_vendor_id, p_method);
END;
$function$;

-- Surface the vendor's current notification_method in the JWT-backing user_data payload,
-- alongside preferred_branch_id.
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
           'notification_method', COALESCE(pv.notification_method, 'email'),
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
