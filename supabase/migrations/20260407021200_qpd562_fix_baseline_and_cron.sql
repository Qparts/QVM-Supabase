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

CREATE OR REPLACE FUNCTION public._pick_available_manager(p_branch_id int, p_slot smallint, p_date date)
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

  IF v_main IS NOT NULL AND public._am_is_available(v_main, p_slot, p_date) THEN RETURN v_main; END IF;
  IF v_sub1 IS NOT NULL AND public._am_is_available(v_sub1, p_slot, p_date) THEN RETURN v_sub1; END IF;
  IF v_sub2 IS NOT NULL AND public._am_is_available(v_sub2, p_slot, p_date) THEN RETURN v_sub2; END IF;
  IF v_fallback IS NOT NULL AND public._am_is_available(v_fallback, p_slot, p_date) THEN RETURN v_fallback; END IF;
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

CREATE OR REPLACE FUNCTION public.create_account_manager_attendance(
  p_user_id uuid,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_manager uuid;
  v_type text;
  v_start date;
  v_end date;
  v_slots smallint[];
  v_id bigint;
  v_err text[] := ARRAY[]::text[];
  v_is_am boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_manager := (p_payload->>'account_manager_id')::uuid;
  v_type := lower(trim(both from p_payload->>'record_type'));
  v_start := (p_payload->>'start_date')::date;
  v_end := COALESCE((p_payload->>'end_date')::date, v_start);
  v_slots := (SELECT array_agg((x)::smallint) FROM jsonb_array_elements_text(COALESCE(p_payload->'slots','[]'::jsonb)) AS t(x));

  IF v_manager IS NULL THEN v_err := array_append(v_err, 'Account Manager is required'); END IF;
  IF v_type IS NULL OR v_type NOT IN ('vacation','excuse','overtime') THEN v_err := array_append(v_err, 'Invalid record type'); END IF;
  IF v_start IS NULL THEN v_err := array_append(v_err, 'Start Date is required'); END IF;
  IF v_type = 'vacation' AND v_end < v_start THEN v_err := array_append(v_err, 'End Date must be on or after Start Date'); END IF;
  IF v_type IN ('excuse','overtime') THEN
    IF v_end IS NULL THEN v_end := v_start; END IF;
    IF v_slots IS NULL OR array_length(v_slots,1) IS NULL THEN v_err := array_append(v_err, 'Slots are required for Excuse or Overtime'); END IF;
    IF v_type = 'excuse' AND array_length(v_slots,1) <> 1 THEN v_err := array_append(v_err, 'Excuse must target exactly one slot'); END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE u.user_id = v_manager AND lower(r.list_data) IN ('qparts account manager')
  ) INTO v_is_am;
  IF NOT v_is_am THEN v_err := array_append(v_err, 'Selected user is not an Account Manager'); END IF;

  IF array_length(v_err,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_err);
  END IF;

  IF v_type IN ('excuse','overtime') THEN
    IF EXISTS (
      SELECT 1 FROM qvm_new_apps.account_manager_attendance a
      WHERE a.account_manager = v_manager
        AND lower(a.record_type) = v_type
        AND a.start_date = v_start AND a.end_date = v_end
        AND (a.slots && v_slots)
    ) THEN
      RETURN jsonb_build_object('status','error','errors', ARRAY['Duplicate record exists for this manager, date, and slot(s).']);
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.account_manager_attendance(account_manager, record_type, start_date, end_date, slots, created_by)
  VALUES (v_manager, v_type, v_start, v_end, v_slots, p_user_id)
  RETURNING id INTO v_id;

  IF current_date BETWEEN v_start AND v_end THEN
    PERFORM public.apply_attendance_for_today();
  END IF;

  RETURN jsonb_build_object('status','success','attendance_id', v_id);
END;
$$;

DO $$
BEGIN
  PERFORM cron.schedule('am_alloc_recalc_daily', '5 0 * * *', $$
    SELECT public.recalculate_account_manager_allocations_baseline();
    SELECT public.apply_attendance_for_today();
  $$);
EXCEPTION WHEN OTHERS THEN NULL;
END$$;

COMMIT;
