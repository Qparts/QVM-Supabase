-- A branch may have several managers, ordered.
--
-- admin_set_branch_account_manager took one person and put them in every slot, every day. The
-- schema was never that narrow: account_manager_allocations has a column per working day, and
-- account_manager_branches holds a main plus three substitutes per slot. Those exist precisely so a
-- branch can be covered by more than one person.
--
-- So the list is now ordered and the two tables are filled the way they were meant to be:
--
--   * the DAYS are dealt round-robin, so two managers means one takes Saturday, Monday and
--     Wednesday and the other Sunday, Tuesday and Thursday. Each is genuinely on duty, rather than
--     the second being a name that never gets picked.
--   * the FALLBACK CHAIN is the same list in order — main, then up to three substitutes — so when
--     the manager on duty is unavailable, get_account_manager walks to the next one.
--
-- Four is the ceiling for the fallback chain because the table has four columns. More than four are
-- accepted and share the days; only the first four can stand in for each other.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_managers(
  p_customer_id integer,
  p_user_ids    uuid[]
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ids uuid[] := COALESCE(p_user_ids, ARRAY[]::uuid[]);
  v_n   integer;
  v_slot smallint;
  v_days text[] := ARRAY['saturday','sunday','monday','tuesday','wednesday','thursday'];
  v_day text;
  v_i   integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
  END IF;

  v_n := COALESCE(array_length(v_ids, 1), 0);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'A branch needs at least one manager — without one its orders are refused before they are numbered.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) u
              WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data
                                 WHERE user_id = u AND deleted_at IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'One of those users does not exist');
  END IF;
  IF (SELECT count(DISTINCT u) FROM unnest(v_ids) u) <> v_n THEN
    RETURN jsonb_build_object('success', false, 'error', 'The same person is listed twice');
  END IF;

  -- Replaced wholesale: this call states who covers the branch, and merging would leave people
  -- behind who were meant to be removed.
  DELETE FROM qvm_new_apps.account_manager_allocations WHERE customer_id = p_customer_id;
  DELETE FROM qvm_new_apps.account_manager_branches   WHERE customer_id = p_customer_id;

  FOREACH v_slot IN ARRAY ARRAY[1, 2, 3]::smallint[] LOOP
    INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
    VALUES (p_customer_id, v_slot, now());

    -- Deal the days out in turn. One manager takes every day, which is the old behaviour.
    v_i := 0;
    FOREACH v_day IN ARRAY v_days LOOP
      EXECUTE format(
        'UPDATE qvm_new_apps.account_manager_allocations SET %I = $1 WHERE customer_id = $2 AND slot_number = $3',
        v_day)
      USING v_ids[(v_i % v_n) + 1], p_customer_id, v_slot;
      v_i := v_i + 1;
    END LOOP;

    INSERT INTO qvm_new_apps.account_manager_branches
      (customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager)
    VALUES (p_customer_id, v_slot, v_ids[1], v_ids[2], v_ids[3], v_ids[4]);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'manager_count', v_n,
    'readiness', qvm_new_apps.branch_quotation_readiness(p_customer_id)));
END $$;

-- Who covers a branch today, in the order they were given.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_branch_managers(p_customer_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', m.uid, 'user_name', ud.user_name, 'email', ud.email,
             'role_name', ld.list_data,
             'days', m.days)
           ORDER BY m.rank)
    FROM (
      SELECT b.main_account_manager AS uid, 1 AS rank FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.main_account_manager IS NOT NULL
      UNION ALL
      SELECT b.first_substitute, 2 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.first_substitute IS NOT NULL
      UNION ALL
      SELECT b.second_substitute, 3 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.second_substitute IS NOT NULL
      UNION ALL
      SELECT b.fallback_account_manager, 4 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.fallback_account_manager IS NOT NULL
    ) r
    CROSS JOIN LATERAL (
      SELECT r.uid, r.rank,
             -- The days this person is actually on duty, read back from the allocation.
             (SELECT COALESCE(jsonb_agg(d ORDER BY ord), '[]'::jsonb)
                FROM (SELECT 'Sat' AS d, 1 AS ord WHERE a.saturday = r.uid
                      UNION ALL SELECT 'Sun', 2 WHERE a.sunday = r.uid
                      UNION ALL SELECT 'Mon', 3 WHERE a.monday = r.uid
                      UNION ALL SELECT 'Tue', 4 WHERE a.tuesday = r.uid
                      UNION ALL SELECT 'Wed', 5 WHERE a.wednesday = r.uid
                      UNION ALL SELECT 'Thu', 6 WHERE a.thursday = r.uid) x) AS days
        FROM qvm_new_apps.account_manager_allocations a
       WHERE a.customer_id = p_customer_id AND a.slot_number = 1
    ) m
    JOIN qvm_new_apps.user_data ud ON ud.user_id = m.uid
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
  ), '[]'::jsonb));
END $$;

-- The single-manager entry point stays, as one item in a list. Nothing else has to change to keep
-- working, and there is one implementation underneath.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_account_manager(
  p_customer_id integer, p_user_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.admin_set_branch_managers(p_customer_id, ARRAY[p_user_id]);
$$;

CREATE OR REPLACE FUNCTION public.admin_set_branch_managers(p_customer_id integer, p_user_ids uuid[])
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_branch_managers(p_customer_id, p_user_ids); $$;

CREATE OR REPLACE FUNCTION public.admin_get_branch_managers(p_customer_id integer)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_get_branch_managers(p_customer_id); $$;

GRANT EXECUTE ON FUNCTION public.admin_set_branch_managers(integer, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_branch_managers(integer) TO authenticated;
