-- set_vendor_preferred_branch was missing the is_internal_user() OR-clause that every other
-- vendor-branch function has (create_vendor_branch, update_vendor_branch, list_vendor_branches
-- all check `is_internal_user() OR is_vendor_admin_for(...)`), so internal QVM admins could
-- never set a vendor's preferred branch — only a vendor-side admin user could. Surfaced by the
-- new admin Branches UI, which needs to set preferred_branch_id right after creating a vendor's
-- first branch.

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
  v_is_admin := qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id);

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
