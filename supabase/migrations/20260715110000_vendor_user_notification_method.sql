-- Pivot notification_method from a company-wide setting (vendors.notification_method, added in
-- 20260715100000) to a per-vendor-user setting, managed by the admin-vendor from the Branches &
-- Users page's "Vendor Users" table, one row per user — different users at the same vendor may
-- want different channels.

ALTER TABLE qvm_new_apps.vendors DROP COLUMN IF EXISTS notification_method;
DROP FUNCTION IF EXISTS qvm_new_apps.set_vendor_notification_method(integer, text);
DROP FUNCTION IF EXISTS public.set_vendor_notification_method(integer, text);

ALTER TABLE qvm_new_apps.user_data
  ADD COLUMN IF NOT EXISTS notification_method text NOT NULL DEFAULT 'email'
  CHECK (notification_method IN ('email', 'whatsapp'));

-- Admin-vendor sets it for any user at their company; a user may also set their own.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_user_notification_method(p_user_id uuid, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_target_vendor integer;
BEGIN
  IF p_method NOT IN ('email', 'whatsapp') THEN
    RETURN jsonb_build_object('status', false, 'message', 'Invalid notification method');
  END IF;

  SELECT user_vendor INTO v_target_vendor FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_target_vendor IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'User not found');
  END IF;

  IF p_user_id <> auth.uid() AND NOT qvm_new_apps.is_vendor_admin_for(v_target_vendor) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Not authorized');
  END IF;

  UPDATE qvm_new_apps.user_data
  SET notification_method = p_method
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_vendor_user_notification_method(p_user_id uuid, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN qvm_new_apps.set_vendor_user_notification_method(p_user_id, p_method);
END;
$function$;

-- Batch lookup for the Vendor Users table (avoids N calls to render N rows).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_users_notification_methods(p_vendor_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', u.user_id,
           'notification_method', u.notification_method
         )), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.user_data u
  WHERE u.user_vendor = p_vendor_id;

  RETURN v_result;
END;
$function$;

-- Resolves a single representative notification channel for a vendor(+branch) — used by the
-- RFQ/PO n8n webhook builders, which send one message per vendor. Prefers a user assigned to the
-- given branch, falls back to any user at the vendor, then defaults to 'email' for login-less
-- vendor companies with no users at all.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_notification_method(p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_method text;
BEGIN
  IF p_vendor_branch_id IS NOT NULL THEN
    SELECT u.notification_method INTO v_method
    FROM qvm_new_apps.vendor_branch_users vbu
    JOIN qvm_new_apps.user_data u ON u.user_id = vbu.user_id
    WHERE vbu.vendor_branch_id = p_vendor_branch_id AND u.user_vendor = p_vendor_id
    LIMIT 1;
  END IF;

  IF v_method IS NULL THEN
    SELECT u.notification_method INTO v_method
    FROM qvm_new_apps.user_data u
    WHERE u.user_vendor = p_vendor_id
    ORDER BY u.user_id
    LIMIT 1;
  END IF;

  RETURN COALESCE(v_method, 'email');
END;
$function$;

-- The JWT-backing user_data payload now reflects the caller's OWN notification preference
-- (per-user), not a company default.
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
           'notification_method', COALESCE(u.notification_method, 'email'),
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
