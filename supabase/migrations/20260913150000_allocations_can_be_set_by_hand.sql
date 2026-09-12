-- An allocation can be set by hand, and the recalculation stops undoing it.
--
-- account_manager_allocations is derived: a trigger recalculates it from the assignment chain on
-- each branch and the attendance recorded against each manager. That is the right default and it is
-- not always right — somebody covers a day the roster does not know about, and the person running
-- the company needs to say so directly rather than reverse-engineer which slot and which day off
-- would produce the answer they already have.
--
-- Writing into the derived table itself would not survive: the next recalculation, which fires on
-- any change to any branch's managers, would overwrite it with no trace. So a hand-set cell is kept
-- in its own table and applied on top of every recalculation. The two facts stay separate — what
-- the roster computes, and what a person decided — and reverting a cell is deleting one row rather
-- than guessing what the computed value used to be.
--
-- A row whose account_manager is NULL is not the absence of an override: it is "nobody covers this
-- cell", set deliberately. The absence of an override is the absence of a row.

CREATE TABLE IF NOT EXISTS qvm_new_apps.account_manager_allocation_overrides (
  customer_id     integer  NOT NULL REFERENCES qvm_new_apps.client_branches(customer_id) ON DELETE CASCADE,
  slot_number     smallint NOT NULL CHECK (slot_number BETWEEN 1 AND 3),
  day_key         text     NOT NULL CHECK (day_key IN ('saturday','sunday','monday','tuesday','wednesday','thursday')),
  account_manager uuid,
  set_by          uuid,
  set_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, slot_number, day_key)
);

GRANT ALL ON qvm_new_apps.account_manager_allocation_overrides TO service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.apply_allocation_overrides()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  -- One statement per day: the derived table stores the week as six columns, so there is no column
  -- to parameterise and dynamic SQL would buy nothing but a place for a typo to hide.
  UPDATE qvm_new_apps.account_manager_allocations a SET saturday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'saturday';
  UPDATE qvm_new_apps.account_manager_allocations a SET sunday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'sunday';
  UPDATE qvm_new_apps.account_manager_allocations a SET monday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'monday';
  UPDATE qvm_new_apps.account_manager_allocations a SET tuesday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'tuesday';
  UPDATE qvm_new_apps.account_manager_allocations a SET wednesday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'wednesday';
  UPDATE qvm_new_apps.account_manager_allocations a SET thursday = o.account_manager
    FROM qvm_new_apps.account_manager_allocation_overrides o
   WHERE o.customer_id = a.customer_id AND o.slot_number = a.slot_number AND o.day_key = 'thursday';
END $$;

CREATE OR REPLACE FUNCTION public.recalculate_account_manager_allocations_baseline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  rec_branch record;
  s smallint;
  d date := current_date;
  d_sat date := public._date_for_weekday(d, 6);
  d_sun date := public._date_for_weekday(d, 0);
  d_mon date := public._date_for_weekday(d, 1);
  d_tue date := public._date_for_weekday(d, 2);
  d_wed date := public._date_for_weekday(d, 3);
  d_thu date := public._date_for_weekday(d, 4);
  m uuid;
BEGIN
  FOR rec_branch IN SELECT customer_id::int AS branch_id FROM qvm_new_apps.client_branches LOOP
    FOR s IN 1..3 LOOP
      -- Ensure row exists per branch + slot
      INSERT INTO qvm_new_apps.account_manager_allocations(customer_id, slot_number, calculated_at)
      SELECT rec_branch.branch_id, s, now()
      WHERE NOT EXISTS (
        SELECT 1 FROM qvm_new_apps.account_manager_allocations WHERE customer_id = rec_branch.branch_id AND slot_number = s
      );

      -- Saturday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_sat);
      UPDATE qvm_new_apps.account_manager_allocations SET saturday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      -- Sunday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_sun);
      UPDATE qvm_new_apps.account_manager_allocations SET sunday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      -- Monday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_mon);
      UPDATE qvm_new_apps.account_manager_allocations SET monday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      -- Tuesday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_tue);
      UPDATE qvm_new_apps.account_manager_allocations SET tuesday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      -- Wednesday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_wed);
      UPDATE qvm_new_apps.account_manager_allocations SET wednesday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      -- Thursday
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_thu);
      UPDATE qvm_new_apps.account_manager_allocations SET thursday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;
    END LOOP;
  END LOOP;

  -- Last word to the hand-set cells. Everything above is derived from the assignment chain and the
  -- attendance behind it; a cell someone set on purpose is not derived, and without this line every
  -- recalculation — and one fires on any change to a branch's managers — would quietly undo it.
  PERFORM qvm_new_apps.apply_allocation_overrides();
END;
$$;

-- ─────────────────────────────────────────────────────────────────────── setting one cell by hand
CREATE OR REPLACE FUNCTION public.set_account_manager_allocation(
  p_user_id   uuid,
  p_branch_id integer,
  p_slot      integer,
  p_day       text,
  p_manager   uuid    DEFAULT NULL,
  p_clear     boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_day text := lower(btrim(p_day));
  v_dow int;
  v_value uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('admin','pricing supervisor'))
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  -- Qparts Admin reaches every branch; a Company Admin reaches their own and is refused the rest.
  PERFORM qvm_new_apps.assert_am_branch_in_scope(v_uid, p_branch_id);

  IF v_day NOT IN ('saturday','sunday','monday','tuesday','wednesday','thursday') THEN
    RETURN jsonb_build_object('success', false, 'error', format('%s is not a working day', p_day));
  END IF;
  IF p_slot NOT BETWEEN 1 AND 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Slot must be 1, 2 or 3');
  END IF;
  IF p_manager IS NOT NULL AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data WHERE user_id = p_manager) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That user does not exist');
  END IF;

  -- The row has to exist before either branch of this can write to it: a branch that has never been
  -- through a recalculation has no allocation row at all.
  INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
  SELECT p_branch_id, p_slot::smallint, now()
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations
                     WHERE customer_id = p_branch_id AND slot_number = p_slot::smallint);

  IF p_clear THEN
    DELETE FROM qvm_new_apps.account_manager_allocation_overrides
     WHERE customer_id = p_branch_id AND slot_number = p_slot::smallint AND day_key = v_day;

    -- Put the computed answer back in the cell, rather than leaving the hand-set one sitting there
    -- until something else happens to trigger a recalculation.
    v_dow := CASE v_day WHEN 'sunday' THEN 0 WHEN 'monday' THEN 1 WHEN 'tuesday' THEN 2
                        WHEN 'wednesday' THEN 3 WHEN 'thursday' THEN 4 ELSE 6 END;
    v_value := public._pick_available_manager_weekly(
                 p_branch_id, p_slot::smallint, public._date_for_weekday(current_date, v_dow));
  ELSE
    INSERT INTO qvm_new_apps.account_manager_allocation_overrides
      (customer_id, slot_number, day_key, account_manager, set_by, set_at)
    VALUES (p_branch_id, p_slot::smallint, v_day, p_manager, v_uid, now())
    ON CONFLICT (customer_id, slot_number, day_key) DO UPDATE
      SET account_manager = EXCLUDED.account_manager, set_by = EXCLUDED.set_by, set_at = now();
    v_value := p_manager;
  END IF;

  EXECUTE format(
    'UPDATE qvm_new_apps.account_manager_allocations SET %I = $1 WHERE customer_id = $2 AND slot_number = $3',
    v_day)
  USING v_value, p_branch_id, p_slot::smallint;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'branch_id', p_branch_id,
    'slot', p_slot,
    'day', v_day,
    'account_manager', v_value,
    'account_manager_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = v_value),
    'is_override', NOT p_clear));
END $$;

REVOKE ALL ON FUNCTION public.set_account_manager_allocation(uuid, integer, integer, text, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_account_manager_allocation(uuid, integer, integer, text, uuid, boolean) TO authenticated;

-- ───────────────────────────────────────────── the grid says which cells a person set, and who may
CREATE OR REPLACE FUNCTION public.get_account_manager_allocations_dashboard(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_scope integer[];
  v_can_edit boolean := false;
  v_rows jsonb := '[]'::jsonb;
  v_last timestamptz := NULL;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_scope := qvm_new_apps.get_internal_branch_scope(v_uid);

  -- The same test the Branch Assignments tab uses: whoever may name a branch's managers may also
  -- overrule the day they end up covering.
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('admin','pricing supervisor'))
  ) INTO v_can_edit;

  SELECT MAX(calculated_at) INTO v_last FROM qvm_new_apps.account_manager_allocations;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      COALESCE(vb.name, cb.branch_name) AS branch_name,
      cb.workshop_id,
      vw.name AS workshop_name,
      -- Which cells were set by hand, keyed the way the grid names them, so the screen can mark
      -- them and offer to put them back.
      COALESCE((SELECT array_agg(o.day_key || '_s' || o.slot_number ORDER BY o.day_key, o.slot_number)
                  FROM qvm_new_apps.account_manager_allocation_overrides o
                 WHERE o.customer_id = cb.customer_id), ARRAY[]::text[]) AS overrides,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.saturday)::text END))::uuid  AS saturday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.saturday)::text END))::uuid  AS saturday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.saturday)::text END))::uuid  AS saturday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.sunday)::text END))::uuid    AS sunday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.sunday)::text END))::uuid    AS sunday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.sunday)::text END))::uuid    AS sunday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.monday)::text END))::uuid    AS monday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.monday)::text END))::uuid    AS monday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.monday)::text END))::uuid    AS monday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.tuesday)::text END))::uuid   AS tuesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.tuesday)::text END))::uuid   AS tuesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.tuesday)::text END))::uuid   AS tuesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.wednesday)::text END))::uuid AS wednesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.wednesday)::text END))::uuid AS wednesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.wednesday)::text END))::uuid AS wednesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.thursday)::text END))::uuid  AS thursday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.thursday)::text END))::uuid  AS thursday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.thursday)::text END))::uuid  AS thursday_s3
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = cb.customer_id
    LEFT JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = cb.workshop_id
    LEFT JOIN qvm_new_apps.account_manager_allocations a ON a.customer_id = cb.customer_id
    WHERE (v_scope IS NULL OR cb.customer_id = ANY(v_scope))
      AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id)
    GROUP BY cb.customer_id, vb.name, cb.branch_name, cb.workshop_id, vw.name
  ) x;

  RETURN jsonb_build_object('rows', v_rows, 'last_calculated_at', v_last, 'can_edit', v_can_edit);
END $$;
