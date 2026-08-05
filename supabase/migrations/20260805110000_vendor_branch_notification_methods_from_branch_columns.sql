-- Simplifies get_vendor_branch_notification_methods (added 20260805100000) to read the actual
-- per-branch vendor_branches.notify_by_email/notify_by_whatsapp columns directly, settable from
-- the vendor dashboard's Edit Branch modal, instead of aggregating each individual vendor-user's
-- own self-service preference. One clear setting per branch, not several that can disagree.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_branch_notification_methods(p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL::bigint)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_email boolean;
  v_whatsapp boolean;
  v_result text[] := ARRAY[]::text[];
BEGIN
  IF p_vendor_branch_id IS NOT NULL THEN
    SELECT notify_by_email, notify_by_whatsapp INTO v_email, v_whatsapp
    FROM qvm_new_apps.vendor_branches
    WHERE vendor_branch_id = p_vendor_branch_id AND vendor_id = p_vendor_id;
  END IF;

  -- Legacy non-branch vendors (p_vendor_branch_id is null) or a branch with no row found fall
  -- back to the vendor-level company setting, same as before this feature existed.
  IF NOT FOUND OR p_vendor_branch_id IS NULL THEN
    SELECT notify_by_email, notify_by_whatsapp INTO v_email, v_whatsapp
    FROM qvm_new_apps.vendors WHERE vendor_id = p_vendor_id;
  END IF;

  IF v_email THEN v_result := array_append(v_result, 'email'); END IF;
  IF v_whatsapp THEN v_result := array_append(v_result, 'whatsapp'); END IF;
  IF array_length(v_result, 1) IS NULL THEN v_result := ARRAY['email']; END IF;

  RETURN v_result;
END;
$function$;
