-- Synced from QVM/test branch applied migration history (version 20260408064340, name: qpd453_allocations_dashboard)
BEGIN;

SET search_path TO qvm_new_apps, public;

-- Recreate baseline recalculation to ensure rows exist and populate all days
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
END;
$$;

-- Dashboard RPC: returns rows and last calculation timestamp
CREATE OR REPLACE FUNCTION public.get_account_manager_allocations_dashboard(
  p_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean := false;
  v_rows jsonb := '[]'::jsonb;
  v_last timestamptz := NULL;
BEGIN
  SELECT (
    EXISTS (
      SELECT 1 FROM qvm_new_apps.user_data u
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_id = p_user_id AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
    )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT MAX(calculated_at) INTO v_last FROM qvm_new_apps.account_manager_allocations;

  WITH a AS (
    SELECT * FROM qvm_new_apps.account_manager_allocations
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.company_name AS branch_name,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.saturday)::text END) AS uuid) AS saturday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.saturday)::text END) AS uuid) AS saturday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.saturday)::text END) AS uuid) AS saturday_s3,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.sunday)::text END) AS uuid) AS sunday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.sunday)::text END) AS uuid) AS sunday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.sunday)::text END) AS uuid) AS sunday_s3,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.monday)::text END) AS uuid) AS monday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.monday)::text END) AS uuid) AS monday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.monday)::text END) AS uuid) AS monday_s3,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.tuesday)::text END) AS uuid) AS tuesday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.tuesday)::text END) AS uuid) AS tuesday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.tuesday)::text END) AS uuid) AS tuesday_s3,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.wednesday)::text END) AS uuid) AS wednesday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.wednesday)::text END) AS uuid) AS wednesday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.wednesday)::text END) AS uuid) AS wednesday_s3,
      CAST(MAX(CASE WHEN a.slot_number = 1 THEN (a.thursday)::text END) AS uuid) AS thursday_s1,
      CAST(MAX(CASE WHEN a.slot_number = 2 THEN (a.thursday)::text END) AS uuid) AS thursday_s2,
      CAST(MAX(CASE WHEN a.slot_number = 3 THEN (a.thursday)::text END) AS uuid) AS thursday_s3
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN a ON a.customer_id = cb.customer_id
    GROUP BY cb.customer_id, cb.company_name
  ) x;

  RETURN jsonb_build_object('rows', v_rows, 'last_calculated_at', v_last);
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_manager_allocations_dashboard(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_allocations_dashboard(uuid) TO authenticated;

-- Triggers to auto-refresh on mapping/schedule updates
CREATE OR REPLACE FUNCTION public._trg_recalc_allocations_branches()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'qvm_new_apps','public'
AS $$
BEGIN
  PERFORM public.recalculate_account_manager_allocations_baseline();
  RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_recalc_allocations_branches
AFTER INSERT OR UPDATE OR DELETE ON qvm_new_apps.account_manager_branches
FOR EACH STATEMENT EXECUTE FUNCTION public._trg_recalc_allocations_branches();

CREATE OR REPLACE FUNCTION public._trg_recalc_allocations_slots()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'qvm_new_apps','public'
AS $$
BEGIN
  PERFORM public.recalculate_account_manager_allocations_baseline();
  RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_recalc_allocations_slots
AFTER INSERT OR UPDATE OR DELETE ON qvm_new_apps.account_manager_slots
FOR EACH STATEMENT EXECUTE FUNCTION public._trg_recalc_allocations_slots();

COMMIT;;
