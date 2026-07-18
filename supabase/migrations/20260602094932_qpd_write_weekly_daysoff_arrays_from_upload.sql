-- Synced from QVM/test branch applied migration history (version 20260602094932, name: qpd_write_weekly_daysoff_arrays_from_upload)
BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_account_manager_slots_bulk(
  p_user_id uuid,
  p_month date,
  p_update_weekly_dayoff boolean,
  p_rows jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_errors text[] := ARRAY[]::text[];
  v_processed int := 0;
  v_m date := date_trunc('month', COALESCE(p_month, current_date))::date;
  v_m_next date := (date_trunc('month', COALESCE(p_month, current_date)) + interval '1 month')::date;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF v_m < date_trunc('month', current_date)::date THEN
    RAISE EXCEPTION 'Past months are not permitted';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Invalid rows payload';
  END IF;

  WITH input AS (
    SELECT
      NULLIF(trim(account_manager_id), '')::uuid AS account_manager_id,
      COALESCE(saturday_s1, false) AS saturday_s1,
      COALESCE(saturday_s2, false) AS saturday_s2,
      COALESCE(saturday_s3, false) AS saturday_s3,
      COALESCE(sunday_s1, false) AS sunday_s1,
      COALESCE(sunday_s2, false) AS sunday_s2,
      COALESCE(sunday_s3, false) AS sunday_s3,
      COALESCE(monday_s1, false) AS monday_s1,
      COALESCE(monday_s2, false) AS monday_s2,
      COALESCE(monday_s3, false) AS monday_s3,
      COALESCE(tuesday_s1, false) AS tuesday_s1,
      COALESCE(tuesday_s2, false) AS tuesday_s2,
      COALESCE(tuesday_s3, false) AS tuesday_s3,
      COALESCE(wednesday_s1, false) AS wednesday_s1,
      COALESCE(wednesday_s2, false) AS wednesday_s2,
      COALESCE(wednesday_s3, false) AS wednesday_s3,
      COALESCE(thursday_s1, false) AS thursday_s1,
      COALESCE(thursday_s2, false) AS thursday_s2,
      COALESCE(thursday_s3, false) AS thursday_s3
    FROM jsonb_to_recordset(p_rows) AS x(
      account_manager_id text,
      saturday_s1 boolean,
      saturday_s2 boolean,
      saturday_s3 boolean,
      sunday_s1 boolean,
      sunday_s2 boolean,
      sunday_s3 boolean,
      monday_s1 boolean,
      monday_s2 boolean,
      monday_s3 boolean,
      tuesday_s1 boolean,
      tuesday_s2 boolean,
      tuesday_s3 boolean,
      wednesday_s1 boolean,
      wednesday_s2 boolean,
      wednesday_s3 boolean,
      thursday_s1 boolean,
      thursday_s2 boolean,
      thursday_s3 boolean
    )
  )
  SELECT array_agg(err) FILTER (WHERE err IS NOT NULL)
  INTO v_errors
  FROM (
    SELECT CASE
      WHEN i.account_manager_id IS NULL THEN 'Row missing account_manager_id'
      WHEN u.user_id IS NULL OR r.list_data_id IS NULL THEN 'Unknown Account Manager ID: ' || COALESCE(i.account_manager_id::text, '(blank)')
      WHEN p_update_weekly_dayoff AND (
        ((NOT i.saturday_s1 AND NOT i.saturday_s2 AND NOT i.saturday_s3)::int) +
        ((NOT i.sunday_s1 AND NOT i.sunday_s2 AND NOT i.sunday_s3)::int) +
        ((NOT i.monday_s1 AND NOT i.monday_s2 AND NOT i.monday_s3)::int) +
        ((NOT i.tuesday_s1 AND NOT i.tuesday_s2 AND NOT i.tuesday_s3)::int) +
        ((NOT i.wednesday_s1 AND NOT i.wednesday_s2 AND NOT i.wednesday_s3)::int) +
        ((NOT i.thursday_s1 AND NOT i.thursday_s2 AND NOT i.thursday_s3)::int)
      ) <> 1 THEN 'Exactly one weekly day off is required for ' || COALESCE(u.user_name, i.account_manager_id::text)
      ELSE NULL
    END AS err
    FROM input i
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = i.account_manager_id
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
      AND lower(r.list_data) IN ('qparts account manager', 'account manager')
  ) validation;

  IF array_length(v_errors, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'error', 'errors', v_errors);
  END IF;

  WITH input AS (
    SELECT DISTINCT
      NULLIF(trim(account_manager_id), '')::uuid AS account_manager_id
    FROM jsonb_to_recordset(p_rows) AS x(account_manager_id text)
  )
  INSERT INTO qvm_new_apps.account_manager_slots(
    account_manager,
    slot_number,
    saturday,
    sunday,
    monday,
    tuesday,
    wednesday,
    thursday,
    is_available,
    created_at,
    updated_at
  )
  SELECT
    i.account_manager_id,
    gs.slot_number,
    false,
    false,
    false,
    false,
    false,
    false,
    true,
    now(),
    now()
  FROM input i
  CROSS JOIN generate_series(1, 3) AS gs(slot_number)
  ON CONFLICT (account_manager, slot_number) DO NOTHING;

  WITH input AS (
    SELECT
      NULLIF(trim(account_manager_id), '')::uuid AS account_manager_id,
      COALESCE(saturday_s1, false) AS saturday_s1,
      COALESCE(saturday_s2, false) AS saturday_s2,
      COALESCE(saturday_s3, false) AS saturday_s3,
      COALESCE(sunday_s1, false) AS sunday_s1,
      COALESCE(sunday_s2, false) AS sunday_s2,
      COALESCE(sunday_s3, false) AS sunday_s3,
      COALESCE(monday_s1, false) AS monday_s1,
      COALESCE(monday_s2, false) AS monday_s2,
      COALESCE(monday_s3, false) AS monday_s3,
      COALESCE(tuesday_s1, false) AS tuesday_s1,
      COALESCE(tuesday_s2, false) AS tuesday_s2,
      COALESCE(tuesday_s3, false) AS tuesday_s3,
      COALESCE(wednesday_s1, false) AS wednesday_s1,
      COALESCE(wednesday_s2, false) AS wednesday_s2,
      COALESCE(wednesday_s3, false) AS wednesday_s3,
      COALESCE(thursday_s1, false) AS thursday_s1,
      COALESCE(thursday_s2, false) AS thursday_s2,
      COALESCE(thursday_s3, false) AS thursday_s3
    FROM jsonb_to_recordset(p_rows) AS x(
      account_manager_id text,
      saturday_s1 boolean,
      saturday_s2 boolean,
      saturday_s3 boolean,
      sunday_s1 boolean,
      sunday_s2 boolean,
      sunday_s3 boolean,
      monday_s1 boolean,
      monday_s2 boolean,
      monday_s3 boolean,
      tuesday_s1 boolean,
      tuesday_s2 boolean,
      tuesday_s3 boolean,
      wednesday_s1 boolean,
      wednesday_s2 boolean,
      wednesday_s3 boolean,
      thursday_s1 boolean,
      thursday_s2 boolean,
      thursday_s3 boolean
    )
  ),
  slot_values AS (
    SELECT account_manager_id, 1::smallint AS slot_number, saturday_s1 AS saturday, sunday_s1 AS sunday, monday_s1 AS monday, tuesday_s1 AS tuesday, wednesday_s1 AS wednesday, thursday_s1 AS thursday FROM input
    UNION ALL
    SELECT account_manager_id, 2::smallint AS slot_number, saturday_s2, sunday_s2, monday_s2, tuesday_s2, wednesday_s2, thursday_s2 FROM input
    UNION ALL
    SELECT account_manager_id, 3::smallint AS slot_number, saturday_s3, sunday_s3, monday_s3, tuesday_s3, wednesday_s3, thursday_s3 FROM input
  )
  UPDATE qvm_new_apps.account_manager_slots s
  SET
    saturday = v.saturday,
    sunday = v.sunday,
    monday = v.monday,
    tuesday = v.tuesday,
    wednesday = v.wednesday,
    thursday = v.thursday,
    is_available = true,
    updated_at = now()
  FROM slot_values v
  WHERE s.account_manager = v.account_manager_id
    AND s.slot_number = v.slot_number;

  GET DIAGNOSTICS v_processed = ROW_COUNT;

  IF p_update_weekly_dayoff THEN
    DELETE FROM qvm_new_apps.weekly_daysoff
    WHERE month IN (v_m, v_m_next);

    WITH input AS (
      SELECT
        NULLIF(trim(account_manager_id), '')::uuid AS account_manager_id,
        (NOT COALESCE(saturday_s1, false) AND NOT COALESCE(saturday_s2, false) AND NOT COALESCE(saturday_s3, false)) AS is_sat_off,
        (NOT COALESCE(sunday_s1, false) AND NOT COALESCE(sunday_s2, false) AND NOT COALESCE(sunday_s3, false)) AS is_sun_off,
        (NOT COALESCE(monday_s1, false) AND NOT COALESCE(monday_s2, false) AND NOT COALESCE(monday_s3, false)) AS is_mon_off,
        (NOT COALESCE(tuesday_s1, false) AND NOT COALESCE(tuesday_s2, false) AND NOT COALESCE(tuesday_s3, false)) AS is_tue_off,
        (NOT COALESCE(wednesday_s1, false) AND NOT COALESCE(wednesday_s2, false) AND NOT COALESCE(wednesday_s3, false)) AS is_wed_off,
        (NOT COALESCE(thursday_s1, false) AND NOT COALESCE(thursday_s2, false) AND NOT COALESCE(thursday_s3, false)) AS is_thu_off
      FROM jsonb_to_recordset(p_rows) AS x(
        account_manager_id text,
        saturday_s1 boolean,
        saturday_s2 boolean,
        saturday_s3 boolean,
        sunday_s1 boolean,
        sunday_s2 boolean,
        sunday_s3 boolean,
        monday_s1 boolean,
        monday_s2 boolean,
        monday_s3 boolean,
        tuesday_s1 boolean,
        tuesday_s2 boolean,
        tuesday_s3 boolean,
        wednesday_s1 boolean,
        wednesday_s2 boolean,
        wednesday_s3 boolean,
        thursday_s1 boolean,
        thursday_s2 boolean,
        thursday_s3 boolean
      )
    ),
    grouped AS (
      SELECT
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_sat_off), ARRAY[]::uuid[]) AS saturday,
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_sun_off), ARRAY[]::uuid[]) AS sunday,
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_mon_off), ARRAY[]::uuid[]) AS monday,
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_tue_off), ARRAY[]::uuid[]) AS tuesday,
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_wed_off), ARRAY[]::uuid[]) AS wednesday,
        COALESCE(array_agg(account_manager_id ORDER BY account_manager_id) FILTER (WHERE is_thu_off), ARRAY[]::uuid[]) AS thursday
      FROM input
    )
    INSERT INTO qvm_new_apps.weekly_daysoff(month, saturday, sunday, monday, tuesday, wednesday, thursday)
    SELECT v_m, saturday, sunday, monday, tuesday, wednesday, thursday
    FROM grouped
    UNION ALL
    SELECT v_m_next, saturday, sunday, monday, tuesday, wednesday, thursday
    FROM grouped;
  END IF;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status', 'success', 'processed', v_processed);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_account_manager_slots_bulk(uuid, date, boolean, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_account_manager_slots_bulk(uuid, date, boolean, jsonb) TO authenticated;

COMMIT;;
