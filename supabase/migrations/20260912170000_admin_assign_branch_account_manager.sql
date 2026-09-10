-- Giving a branch an account manager, from the admin screen.
--
-- It is the one prerequisite that cannot be provisioned automatically: a region follows from the
-- city and a numbering sequence can be generated, but there is no defensible way to guess WHO
-- should own a branch's orders. So the readiness check names it and this is where it gets answered.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_account_managers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
             'role_name', ld.list_data,
             'branch_count', (SELECT count(DISTINCT a.customer_id)
                                FROM qvm_new_apps.account_manager_allocations a
                               WHERE ud.user_id IN (a.saturday, a.sunday, a.monday, a.tuesday,
                                                    a.wednesday, a.thursday)))
           ORDER BY ud.user_name)
    FROM qvm_new_apps.user_data ud
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
    -- Qparts Account Manager, and the admins who also carry branches themselves.
    WHERE ud.user_type = 185 AND ud.deleted_at IS NULL AND ud.user_role IN (172, 173)
  ), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_account_manager(
  p_customer_id integer,
  p_user_id     uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data
                  WHERE user_id = p_user_id AND user_type = 185 AND deleted_at IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That user cannot be an account manager');
  END IF;

  -- Replacing rather than adding: this screen answers "who owns this branch", and leaving the old
  -- allocation behind would leave the rotation pointing at two answers.
  DELETE FROM qvm_new_apps.account_manager_allocations WHERE customer_id = p_customer_id;
  DELETE FROM qvm_new_apps.account_manager_branches   WHERE customer_id = p_customer_id;

  PERFORM qvm_new_apps.ensure_branch_account_manager(p_customer_id, p_user_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'readiness', qvm_new_apps.branch_quotation_readiness(p_customer_id)));
END $$;

CREATE OR REPLACE FUNCTION public.admin_list_account_managers() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_list_account_managers(); $$;

CREATE OR REPLACE FUNCTION public.admin_set_branch_account_manager(p_customer_id integer, p_user_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_branch_account_manager(p_customer_id, p_user_id); $$;

GRANT EXECUTE ON FUNCTION public.admin_list_account_managers() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_branch_account_manager(integer, uuid) TO authenticated;
