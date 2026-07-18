BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public._am_is_available_weekly(p_manager uuid, p_slot smallint, p_date date)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  dow int := extract(dow from p_date);
  v_slot qvm_new_apps.account_manager_slots%ROWTYPE;
  v_day_ok boolean := false;
BEGIN
  SELECT * INTO v_slot
  FROM qvm_new_apps.account_manager_slots s
  WHERE s.account_manager = p_manager AND s.slot_number = p_slot
  LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;

  IF dow = 6 THEN v_day_ok := COALESCE(v_slot.saturday, false);
  ELSIF dow = 0 THEN v_day_ok := COALESCE(v_slot.sunday, false);
  ELSIF dow = 1 THEN v_day_ok := COALESCE(v_slot.monday, false);
  ELSIF dow = 2 THEN v_day_ok := COALESCE(v_slot.tuesday, false);
  ELSIF dow = 3 THEN v_day_ok := COALESCE(v_slot.wednesday, false);
  ELSIF dow = 4 THEN v_day_ok := COALESCE(v_slot.thursday, false);
  ELSE v_day_ok := false; END IF;

  IF NOT v_day_ok OR NOT COALESCE(v_slot.is_available, false) THEN RETURN false; END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public._pick_available_manager_weekly(p_branch_id int, p_slot smallint, p_date date)
RETURNS uuid
LANGUAGE plpgsql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_main uuid;
  v_sub1 uuid;
  v_sub2 uuid;
  v_fallback uuid;
BEGIN
  SELECT
    CAST(MAX(CASE WHEN slot_number = p_slot THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = p_slot THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = p_slot THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = p_slot THEN (fallback_account_manager)::text END) AS uuid)
  INTO v_main, v_sub1, v_sub2, v_fallback
  FROM qvm_new_apps.account_manager_branches
  WHERE customer_id = p_branch_id;

  IF v_main IS NOT NULL AND public._am_is_available_weekly(v_main, p_slot, p_date) THEN RETURN v_main; END IF;
  IF v_sub1 IS NOT NULL AND public._am_is_available_weekly(v_sub1, p_slot, p_date) THEN RETURN v_sub1; END IF;
  IF v_sub2 IS NOT NULL AND public._am_is_available_weekly(v_sub2, p_slot, p_date) THEN RETURN v_sub2; END IF;
  IF v_fallback IS NOT NULL AND public._am_is_available_weekly(v_fallback, p_slot, p_date) THEN RETURN v_fallback; END IF;
  RETURN NULL;
END;
$$;

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
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_sat);
      UPDATE qvm_new_apps.account_manager_allocations SET saturday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_sun);
      UPDATE qvm_new_apps.account_manager_allocations SET sunday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_mon);
      UPDATE qvm_new_apps.account_manager_allocations SET monday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_tue);
      UPDATE qvm_new_apps.account_manager_allocations SET tuesday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_wed);
      UPDATE qvm_new_apps.account_manager_allocations SET wednesday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
      m := public._pick_available_manager_weekly(rec_branch.branch_id, s, d_thu);
      UPDATE qvm_new_apps.account_manager_allocations SET thursday = m, calculated_at = now() WHERE customer_id = rec_branch.branch_id AND slot_number = s;
    END LOOP;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public._am_daily_job()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
BEGIN
  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM extensions.cron.unschedule('am_alloc_recalc_daily');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    PERFORM extensions.cron.schedule('am_alloc_recalc_daily', '5 0 * * *', $job$
      SELECT public._am_daily_job();
    $job$);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END$$;

COMMIT;
