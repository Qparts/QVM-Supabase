-- Who may be a branch's account manager, decided by the data rather than by a role I guessed at.
--
-- The first version filtered on user_type 185 AND user_role IN (172, 173) — internal users who are
-- Qparts Admin or "Qparts Account Manager". It reads sensibly and it is wrong here:
--
--   * dev has NO user with role 173 at all;
--   * the two people actually allocated as account managers — Al-Dammam and zubair waheed — are
--     user_type 183, role 170.
--
-- So the dropdown listed three people who manage nothing and omitted both who do. Rather than swap
-- one guess for another, the list is now the union of two things that can be checked:
--
--   1. anyone already allocated as an account manager somewhere — they are demonstrably in the job;
--   2. internal users, who are the pool a new one would ordinarily be drawn from.
--
-- Each row says which it is and how many branches it already holds, so the admin is choosing with
-- the facts in front of them instead of trusting a filter to have been right.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_account_managers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', u.user_id,
             'user_name', u.user_name,
             'email', u.email,
             'role_name', u.role_name,
             'is_internal', u.user_type = 185,
             'branch_count', u.branch_count,
             -- Already doing the job somewhere. The admin sorts on this, not on a role name.
             'is_current', u.branch_count > 0)
           ORDER BY u.branch_count DESC, u.user_name)
    FROM (
      SELECT ud.user_id, ud.user_name, ud.email, ud.user_type, ld.list_data AS role_name,
             (SELECT count(DISTINCT b.customer_id)
                FROM qvm_new_apps.account_manager_branches b
               WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                    b.second_substitute, b.fallback_account_manager)) AS branch_count
      FROM qvm_new_apps.user_data ud
      LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
      WHERE ud.deleted_at IS NULL
        AND (
          ud.user_type = 185
          OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches b
                      WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                           b.second_substitute, b.fallback_account_manager))
          OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a
                      WHERE ud.user_id IN (a.saturday, a.sunday, a.monday, a.tuesday,
                                           a.wednesday, a.thursday))
        )
    ) u
  ), '[]'::jsonb));
END $$;

-- The assignment check has to widen to match. Refusing a non-internal user would have refused both
-- of the people currently doing this on dev.
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
                  WHERE user_id = p_user_id AND deleted_at IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  DELETE FROM qvm_new_apps.account_manager_allocations WHERE customer_id = p_customer_id;
  DELETE FROM qvm_new_apps.account_manager_branches   WHERE customer_id = p_customer_id;

  PERFORM qvm_new_apps.ensure_branch_account_manager(p_customer_id, p_user_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'readiness', qvm_new_apps.branch_quotation_readiness(p_customer_id)));
END $$;
