-- Synced from QVM/test branch applied migration history (version 20260602091209, name: qpd_extend_slots_upload_timeout)
BEGIN;

CREATE OR REPLACE FUNCTION public.replace_account_manager_slots_upload(
  p_user_id uuid,
  p_month date,
  p_update_weekly_dayoff boolean,
  p_rows jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
SET statement_timeout TO '5min'
AS $$
DECLARE
  v_allowed boolean;
  v_errors text[] := ARRAY[]::text[];
  v_inserted int := 0;
  v_m date := date_trunc('month', COALESCE(p_month, current_date))::date;
  v_m_next date := (date_trunc('month', COALESCE(p_month, current_date)) + interval '1 month')::date;
  rec jsonb;
  v_name text;
  v_manager uuid;
  s smallint;
  b_sat boolean; b_sun boolean; b_mon boolean; b_tue boolean; b_wed boolean; b_thu boolean;
  v_day_off smallint;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) INTO v_allowed;
  IF NOT v_allowed THEN RAISE EXCEPTION 'Unauthorized'; END IF;

  IF v_m < date_trunc('month', current_date)::date THEN
    RAISE EXCEPTION 'Past months are not permitted';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Invalid rows payload';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_name := NULLIF(trim(both from rec->>'account_manager_name'), '');
    IF v_name IS NULL THEN v_errors := array_append(v_errors, 'Row missing Account Manager Name'); CONTINUE; END IF;
    SELECT u.user_id INTO v_manager
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE lower(u.user_name) = lower(v_name)
      AND lower(r.list_data) IN ('qparts account manager','account manager')
    LIMIT 1;
    IF v_manager IS NULL THEN v_errors := array_append(v_errors, 'Unknown Account Manager: ' || v_name); CONTINUE; END IF;

    v_day_off := NULLIF(rec->>'day_off','')::smallint;
    IF v_day_off IS NOT NULL AND (v_day_off < 0 OR v_day_off > 6) THEN
      v_errors := array_append(v_errors, 'Invalid day_off for ' || v_name);
    END IF;

    FOR s IN 1..3 LOOP
      b_sat := COALESCE((rec->>format('saturday_s%s', s))::boolean, false);
      b_sun := COALESCE((rec->>format('sunday_s%s', s))::boolean, false);
      b_mon := COALESCE((rec->>format('monday_s%s', s))::boolean, false);
      b_tue := COALESCE((rec->>format('tuesday_s%s', s))::boolean, false);
      b_wed := COALESCE((rec->>format('wednesday_s%s', s))::boolean, false);
      b_thu := COALESCE((rec->>format('thursday_s%s', s))::boolean, false);
    END LOOP;
  END LOOP;

  IF array_length(v_errors, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'error', 'errors', v_errors);
  END IF;

  DELETE FROM qvm_new_apps.account_manager_slots
  WHERE true;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_name := trim(both from rec->>'account_manager_name');
    SELECT u.user_id INTO v_manager
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE lower(u.user_name) = lower(v_name)
      AND lower(r.list_data) IN ('qparts account manager','account manager')
    LIMIT 1;

    FOR s IN 1..3 LOOP
      b_sat := COALESCE((rec->>format('saturday_s%s', s))::boolean, false);
      b_sun := COALESCE((rec->>format('sunday_s%s', s))::boolean, false);
      b_mon := COALESCE((rec->>format('monday_s%s', s))::boolean, false);
      b_tue := COALESCE((rec->>format('tuesday_s%s', s))::boolean, false);
      b_wed := COALESCE((rec->>format('wednesday_s%s', s))::boolean, false);
      b_thu := COALESCE((rec->>format('thursday_s%s', s))::boolean, false);

      INSERT INTO qvm_new_apps.account_manager_slots(
        account_manager, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, is_available, created_at, updated_at
      )
      VALUES (v_manager, s, b_sat, b_sun, b_mon, b_tue, b_wed, b_thu, true, now(), now());
      v_inserted := v_inserted + 1;
    END LOOP;

    IF p_update_weekly_dayoff THEN
      v_day_off := NULLIF(rec->>'day_off','')::smallint;
      IF v_day_off IS NOT NULL AND v_day_off BETWEEN 0 AND 6 THEN
        INSERT INTO qvm_new_apps.account_manager_weekly_daysoff(account_manager, month, day_off)
        VALUES (v_manager, v_m, v_day_off)
        ON CONFLICT (account_manager, month) DO UPDATE SET day_off = EXCLUDED.day_off;

        INSERT INTO qvm_new_apps.account_manager_weekly_daysoff(account_manager, month, day_off)
        VALUES (v_manager, v_m_next, v_day_off)
        ON CONFLICT (account_manager, month) DO UPDATE SET day_off = EXCLUDED.day_off;
      END IF;
    END IF;
  END LOOP;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status', 'success', 'inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_account_manager_slots_upload(uuid, date, boolean, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_account_manager_slots_upload(uuid, date, boolean, jsonb) TO authenticated;

COMMIT;;
