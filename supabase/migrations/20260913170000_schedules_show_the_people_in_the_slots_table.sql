-- The Schedules tab lists the people the slots table is actually about.
--
-- get_account_manager_slots_dashboard chose its rows with
--
--   WHERE lower(r.list_data) IN ('qparts account manager','account manager')
--
-- the same mistake the manager dropdown carried: a role named "Account Manager" exists in list 16
-- on no branch, and dev has nobody on "Qparts Account Manager" either. So the tab was empty, and
-- attendance — the thing the whole allocation calculation runs on — could not be recorded for
-- anyone. Meanwhile account_manager_slots itself holds rows for seven people, put there by the
-- migration that seeded it from the old day_off sheet. The table knew who its managers were; only
-- the query did not.
--
-- Both screens now draw their population from one function, so they cannot drift apart again:
-- the roles that staff a branch — Branch Manager, Client Admin, Qparts Admin, by name, since the
-- ids are minted per environment — plus anyone the branch chain or the slots table already knows.
-- Everyone already in account_manager_slots stays visible whatever their role says: a schedule
-- exists for them, and a screen that hides it makes it uneditable rather than absent.
--
-- Same scope rules as everywhere else in this module: a Qparts Admin sees the platform, a Company
-- Admin sees their own people, and choosing a workshop narrows the list to that workshop's.
-- Attendance itself stays the manager's own — it is not per workshop, and the tab says so.

CREATE OR REPLACE FUNCTION qvm_new_apps.assignable_manager_ids(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS TABLE (user_id uuid) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  WITH scope AS (SELECT qvm_new_apps.get_internal_branch_scope(p_user_id) AS ids)
  SELECT u.user_id
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
  CROSS JOIN scope
  WHERE (
          lower(btrim(r.list_data)) IN ('branch manager', 'client admin', 'qparts admin')
          -- Already holding a slot on a branch, or already carrying a schedule: demonstrably in
          -- the job, whatever the role column says about them.
          OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
                      WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                                          a.second_substitute, a.fallback_account_manager))
          OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_slots s
                      WHERE s.account_manager = u.user_id)
        )
    AND (scope.ids IS NULL OR qvm_new_apps.effective_branch_ids(u.user_id) && scope.ids)
    AND (
          p_workshop_id IS NULL
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                      WHERE uw.user_id = u.user_id AND uw.workshop_id = p_workshop_id)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub
                       JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ub.client_branch_id
                      WHERE ub.user_id = u.user_id AND cb.workshop_id = p_workshop_id)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.internal_user_branches iub
                       JOIN qvm_new_apps.client_branches cb ON cb.customer_id = iub.branch_id
                      WHERE iub.user_id = u.user_id AND cb.workshop_id = p_workshop_id)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_companies uc
                       JOIN qvm_new_apps.workshop_companies wc ON wc.company_id = uc.company_id
                      WHERE uc.user_id = u.user_id AND wc.workshop_id = p_workshop_id)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
                       JOIN qvm_new_apps.client_branches cb ON cb.customer_id = a.customer_id
                      WHERE cb.workshop_id = p_workshop_id
                        AND u.user_id IN (a.main_account_manager, a.first_substitute,
                                          a.second_substitute, a.fallback_account_manager))
        );
$$;

-- The dropdown and the schedule now agree by construction.
CREATE OR REPLACE FUNCTION public.list_account_managers(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185
           OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager'))
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      u.user_id AS id,
      COALESCE(NULLIF(btrim(u.user_name), ''), u.email)::text AS name,
      r.list_data::text AS role_name,
      EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
               WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                                   a.second_substitute, a.fallback_account_manager)) AS is_allocated,
      -- Counted within the chosen workshop, so "3 branches" answers the question actually being
      -- asked on this screen rather than one about the whole platform.
      (SELECT count(DISTINCT a.customer_id)
         FROM qvm_new_apps.account_manager_branches a
         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = a.customer_id
        WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                            a.second_substitute, a.fallback_account_manager)
          AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id))::int AS branch_count
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE u.user_id IN (SELECT m.user_id FROM qvm_new_apps.assignable_manager_ids(v_uid, p_workshop_id) m)
  ) x;

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION public.list_account_managers(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_account_managers(uuid, bigint) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────── the schedules tab
DROP FUNCTION IF EXISTS public.get_account_manager_slots_dashboard(uuid, date);

CREATE OR REPLACE FUNCTION public.get_account_manager_slots_dashboard(
  p_user_id uuid,
  p_month date DEFAULT current_date,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_can_edit boolean := false;
  v_rows jsonb := '[]'::jsonb;
  v_m date := date_trunc('month', COALESCE(p_month, current_date))::date;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) INTO v_can_edit;

  WITH mgrs AS (
    SELECT u.user_id, COALESCE(NULLIF(btrim(u.user_name), ''), u.email)::text AS user_name
    FROM qvm_new_apps.user_data u
    WHERE u.user_id IN (SELECT m.user_id FROM qvm_new_apps.assignable_manager_ids(v_uid, p_workshop_id) m)
  ), agg AS (
    SELECT
      m.user_id,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.saturday,false) END) AS saturday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.saturday,false) END) AS saturday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.saturday,false) END) AS saturday_s3,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.sunday,false) END)   AS sunday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.sunday,false) END)   AS sunday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.sunday,false) END)   AS sunday_s3,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.monday,false) END)   AS monday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.monday,false) END)   AS monday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.monday,false) END)   AS monday_s3,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.tuesday,false) END)  AS tuesday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.tuesday,false) END)  AS tuesday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.tuesday,false) END)  AS tuesday_s3,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.wednesday,false) END) AS wednesday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.wednesday,false) END) AS wednesday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.wednesday,false) END) AS wednesday_s3,
      bool_or(CASE WHEN s.slot_number = 1 THEN COALESCE(s.thursday,false) END) AS thursday_s1,
      bool_or(CASE WHEN s.slot_number = 2 THEN COALESCE(s.thursday,false) END) AS thursday_s2,
      bool_or(CASE WHEN s.slot_number = 3 THEN COALESCE(s.thursday,false) END) AS thursday_s3
    FROM mgrs m
    LEFT JOIN qvm_new_apps.account_manager_slots s ON s.account_manager = m.user_id
    GROUP BY m.user_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      m.user_id AS account_manager_id,
      m.user_name AS name,
      r.list_data::text AS role_name,
      -- How much of the roster this person is actually on, so an empty schedule row is visibly a
      -- person who covers branches rather than a stray account.
      (SELECT count(DISTINCT a.customer_id)
         FROM qvm_new_apps.account_manager_branches a
         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = a.customer_id
        WHERE m.user_id IN (a.main_account_manager, a.first_substitute,
                            a.second_substitute, a.fallback_account_manager)
          AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id))::int AS branch_count,
      a.saturday_s1, a.saturday_s2, a.saturday_s3,
      a.sunday_s1, a.sunday_s2, a.sunday_s3,
      a.monday_s1, a.monday_s2, a.monday_s3,
      a.tuesday_s1, a.tuesday_s2, a.tuesday_s3,
      a.wednesday_s1, a.wednesday_s2, a.wednesday_s3,
      a.thursday_s1, a.thursday_s2, a.thursday_s3,
      wd.day_off
    FROM mgrs m
    LEFT JOIN agg a ON a.user_id = m.user_id
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = m.user_id
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    LEFT JOIN qvm_new_apps.account_manager_weekly_daysoff wd
           ON wd.account_manager = m.user_id AND wd.month = v_m
  ) x;

  RETURN jsonb_build_object('can_edit', v_can_edit, 'rows', v_rows, 'month', v_m);
END $$;

REVOKE ALL ON FUNCTION public.get_account_manager_slots_dashboard(uuid, date, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_slots_dashboard(uuid, date, bigint) TO authenticated;

-- ────────────────────────────────────────────────────── a schedule edit stays inside the caller's
-- The inline save asked whether the caller may edit schedules and never whose schedule this is.
CREATE OR REPLACE FUNCTION qvm_new_apps.assert_manager_in_scope(p_user_id uuid, p_account_manager uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_scope integer[] := qvm_new_apps.get_internal_branch_scope(p_user_id);
BEGIN
  IF v_scope IS NOT NULL
     AND NOT COALESCE(qvm_new_apps.effective_branch_ids(p_account_manager) && v_scope, false) THEN
    RAISE EXCEPTION 'Access denied: this account manager is not yours to administer';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.upsert_account_manager_slot_inline(
  p_user_id uuid,
  p_account_manager uuid,
  p_changes jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_changed text[] := ARRAY[]::text[];
  v_has boolean;
  v_month date := date_trunc('month', current_date)::date;
  v_day_off smallint;
  s smallint;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) INTO v_allowed;
  IF NOT v_allowed THEN RAISE EXCEPTION 'Unauthorized'; END IF;

  -- ...and whose schedule this is. A Company Admin may set attendance for their own people; a
  -- Qparts Admin is unrestricted and passes straight through.
  PERFORM qvm_new_apps.assert_manager_in_scope(p_user_id, p_account_manager);

  IF p_changes ? 'day_off' THEN
    v_day_off := (p_changes->>'day_off')::smallint;
    IF v_day_off IS NOT NULL AND v_day_off BETWEEN 0 AND 6 THEN
      INSERT INTO qvm_new_apps.account_manager_weekly_daysoff(account_manager, month, day_off)
      VALUES (p_account_manager, v_month, v_day_off)
      ON CONFLICT (account_manager, month) DO UPDATE SET day_off = EXCLUDED.day_off;
      v_changed := array_append(v_changed, 'day_off');
    END IF;
  END IF;

  FOR s IN 1..3 LOOP
    SELECT EXISTS (
      SELECT 1 FROM qvm_new_apps.account_manager_slots WHERE account_manager = p_account_manager AND slot_number = s
    ) INTO v_has;
    IF NOT v_has THEN
      INSERT INTO qvm_new_apps.account_manager_slots(account_manager, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, is_available, created_at, updated_at)
      VALUES (p_account_manager, s, false, false, false, false, false, false, true, now(), now());
    END IF;

    IF p_changes ? format('saturday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET saturday = COALESCE((p_changes->>format('saturday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('saturday_s%s', s));
    END IF;
    IF p_changes ? format('sunday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET sunday = COALESCE((p_changes->>format('sunday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('sunday_s%s', s));
    END IF;
    IF p_changes ? format('monday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET monday = COALESCE((p_changes->>format('monday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('monday_s%s', s));
    END IF;
    IF p_changes ? format('tuesday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET tuesday = COALESCE((p_changes->>format('tuesday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('tuesday_s%s', s));
    END IF;
    IF p_changes ? format('wednesday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET wednesday = COALESCE((p_changes->>format('wednesday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('wednesday_s%s', s));
    END IF;
    IF p_changes ? format('thursday_s%s', s) THEN
      UPDATE qvm_new_apps.account_manager_slots SET thursday = COALESCE((p_changes->>format('thursday_s%s', s))::boolean, false), updated_at = now()
      WHERE account_manager = p_account_manager AND slot_number = s;
      v_changed := array_append(v_changed, format('thursday_s%s', s));
    END IF;
  END LOOP;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status','success','changed', v_changed);
END;
$$;
