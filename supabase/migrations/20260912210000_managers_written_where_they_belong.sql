-- Writing the coverage chain, and letting the allocation be recalculated from it.
--
-- My first version wrote account_manager_allocations by hand, dealing the days out round-robin.
-- That table is DERIVED. account_manager_branches carries the chain — main plus three substitutes,
-- per branch per slot — account_manager_slots carries each manager's attendance, and a trigger on
-- the branch table calls recalculate_account_manager_allocations_baseline(), which walks the chain
-- for every day and picks the first person actually available that day.
--
-- So the hand-written rows were both redundant and wrong: six allocation rows per branch where
-- there should be three, and days assigned to people the attendance table says are off. Writing
-- only the chain leaves the existing machinery to do what it was built for, and attendance starts
-- mattering again — which is the point of it.
--
-- What "several managers" means here, precisely: one chain per slot, up to four deep. Day by day
-- the first available of the four is on duty, so two managers with complementary attendance really
-- do share the branch, and a third and fourth stand behind them.

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
  IF v_n > 4 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Up to four managers per branch: the coverage chain is a main and three substitutes.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) u
              WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data
                                 WHERE user_id = u AND deleted_at IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'One of those users does not exist');
  END IF;
  IF (SELECT count(DISTINCT u) FROM unnest(v_ids) u) <> v_n THEN
    RETURN jsonb_build_object('success', false, 'error', 'The same person is listed twice');
  END IF;

  -- Only the chain. The allocation is recalculated by the trigger on this table, from this plus
  -- each manager's attendance; writing it here is how the duplicate rows appeared.
  DELETE FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_customer_id;

  FOREACH v_slot IN ARRAY ARRAY[1, 2, 3]::smallint[] LOOP
    INSERT INTO qvm_new_apps.account_manager_branches
      (customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager)
    VALUES (p_customer_id, v_slot, v_ids[1], v_ids[2], v_ids[3], v_ids[4]);
  END LOOP;

  -- A branch with no allocation row at all cannot be served, and the baseline only creates rows for
  -- branches it walks; this makes sure this one has its three before anyone raises an order.
  INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
  SELECT p_customer_id, s, now()
  FROM generate_series(1, 3) s
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a
                     WHERE a.customer_id = p_customer_id AND a.slot_number = s);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'manager_count', v_n,
    'readiness', qvm_new_apps.branch_quotation_readiness(p_customer_id)));
END $$;

-- The provisioning path had the same fault: it wrote allocations directly, with every day set to
-- one person, which the baseline would then overwrite anyway.
CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_branch_account_manager(
  p_customer_id integer,
  p_manager     uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_source integer;
BEGIN
  IF EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_customer_id) THEN
    RETURN true;
  END IF;

  IF p_manager IS NOT NULL THEN
    PERFORM qvm_new_apps.admin_set_branch_managers(p_customer_id, ARRAY[p_manager]);
    RETURN true;
  END IF;

  -- Copy the chain from a sibling branch of the same workshop, then from any branch of the same
  -- company. Copying the chain rather than the allocation keeps attendance in charge of the days.
  SELECT sib.customer_id INTO v_source
  FROM qvm_new_apps.client_branches sib
  WHERE sib.workshop_id = (SELECT workshop_id FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id)
    AND sib.customer_id <> p_customer_id
    AND EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches b WHERE b.customer_id = sib.customer_id)
  ORDER BY sib.customer_id LIMIT 1;

  IF v_source IS NULL THEN
    SELECT sib.customer_id INTO v_source
    FROM qvm_new_apps.client_branches sib
    WHERE sib.list_data_id = (SELECT list_data_id FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id)
      AND sib.customer_id <> p_customer_id
      AND EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches b WHERE b.customer_id = sib.customer_id)
    ORDER BY sib.customer_id LIMIT 1;
  END IF;

  IF v_source IS NULL THEN RETURN false; END IF;

  INSERT INTO qvm_new_apps.account_manager_branches
    (customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager)
  SELECT p_customer_id, b.slot_number, b.main_account_manager, b.first_substitute,
         b.second_substitute, b.fallback_account_manager
  FROM qvm_new_apps.account_manager_branches b
  WHERE b.customer_id = v_source;

  INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
  SELECT p_customer_id, s, now()
  FROM generate_series(1, 3) s
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a
                     WHERE a.customer_id = p_customer_id AND a.slot_number = s);
  RETURN true;
END $$;

-- Readiness follows the chain, not the derived table: a branch is covered when someone is named to
-- cover it, and the allocation is a consequence of that.
CREATE OR REPLACE FUNCTION qvm_new_apps.branch_quotation_readiness(p_customer_id integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT jsonb_build_object(
    'ready', (b.region_id IS NOT NULL AND has_am.ok AND NOT EXISTS (
                SELECT 1 FROM qvm_new_apps.workshop_companies wc
                WHERE wc.workshop_id = b.workshop_id
                  AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.order_number_sequences ons
                                   WHERE ons.lists_data_id = wc.company_id AND ons.region_id = b.region_id))),
    'missing', (
      SELECT COALESCE(jsonb_agg(m), '[]'::jsonb) FROM (
        SELECT 'No region — the order cannot be numbered or routed' AS m WHERE b.region_id IS NULL
        UNION ALL
        SELECT 'No account manager assigned to this branch' WHERE NOT has_am.ok
        UNION ALL
        SELECT 'No order-number sequence for ' || COALESCE(vc.name, 'company ' || wc.company_id)
          FROM qvm_new_apps.workshop_companies wc
          LEFT JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = wc.company_id
         WHERE wc.workshop_id = b.workshop_id AND b.region_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.order_number_sequences ons
                            WHERE ons.lists_data_id = wc.company_id AND ons.region_id = b.region_id)
      ) s)
  )
  FROM qvm_new_apps.client_branches b
  CROSS JOIN LATERAL (
    SELECT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches x
                    WHERE x.customer_id = b.customer_id AND x.main_account_manager IS NOT NULL) AS ok
  ) has_am
  WHERE b.customer_id = p_customer_id;
$$;

-- Read back the chain, with the days the recalculation actually landed on.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_branch_managers(p_customer_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', c.uid, 'rank', c.rank,
             'user_name', ud.user_name, 'email', ud.email, 'role_name', ld.list_data,
             'on_duty', (SELECT COALESCE(jsonb_agg(d ORDER BY ord), '[]'::jsonb)
                           FROM (SELECT 'Sat' AS d, 1 AS ord WHERE a.saturday  = c.uid
                                 UNION ALL SELECT 'Sun', 2 WHERE a.sunday    = c.uid
                                 UNION ALL SELECT 'Mon', 3 WHERE a.monday    = c.uid
                                 UNION ALL SELECT 'Tue', 4 WHERE a.tuesday   = c.uid
                                 UNION ALL SELECT 'Wed', 5 WHERE a.wednesday = c.uid
                                 UNION ALL SELECT 'Thu', 6 WHERE a.thursday  = c.uid) x))
           ORDER BY c.rank)
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
    ) c
    JOIN qvm_new_apps.user_data ud ON ud.user_id = c.uid
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
    LEFT JOIN qvm_new_apps.account_manager_allocations a
           ON a.customer_id = p_customer_id AND a.slot_number = 1
  ), '[]'::jsonb));
END $$;
