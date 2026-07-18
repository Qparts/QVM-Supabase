BEGIN;

SET search_path TO qvm_new_apps, public;

-- Create dedicated AM weekly day off table
CREATE TABLE IF NOT EXISTS qvm_new_apps.account_manager_weekly_daysoff (
  id              bigserial PRIMARY KEY,
  account_manager uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  month           date NOT NULL,
  day_off         smallint NOT NULL CHECK (day_off BETWEEN 0 AND 6),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_manager, month)
);

-- Dashboard RPC using new table
CREATE OR REPLACE FUNCTION public.get_account_manager_slots_dashboard(
  p_user_id uuid,
  p_month date DEFAULT current_date
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_can_edit boolean := false;
  v_rows jsonb := '[]'::jsonb;
  v_m date := date_trunc('month', COALESCE(p_month, current_date))::date;
BEGIN
  SELECT (
    EXISTS (
      SELECT 1
      FROM qvm_new_apps.user_data u
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_id = p_user_id
        AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
    )
  ) INTO v_can_edit;

  WITH mgrs AS (
    SELECT u.user_id, COALESCE(u.user_name, u.email)::text AS user_name
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE lower(r.list_data) IN ('qparts account manager','account manager')
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
      a.saturday_s1, a.saturday_s2, a.saturday_s3,
      a.sunday_s1, a.sunday_s2, a.sunday_s3,
      a.monday_s1, a.monday_s2, a.monday_s3,
      a.tuesday_s1, a.tuesday_s2, a.tuesday_s3,
      a.wednesday_s1, a.wednesday_s2, a.wednesday_s3,
      a.thursday_s1, a.thursday_s2, a.thursday_s3,
      wd.day_off
    FROM mgrs m
    LEFT JOIN agg a ON a.user_id = m.user_id
    LEFT JOIN qvm_new_apps.account_manager_weekly_daysoff wd ON wd.account_manager = m.user_id AND wd.month = v_m
  ) x;

  RETURN jsonb_build_object('can_edit', v_can_edit, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_manager_slots_dashboard(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_slots_dashboard(uuid, date) TO authenticated;

-- Inline upsert using the new table
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

REVOKE ALL ON FUNCTION public.upsert_account_manager_slot_inline(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_account_manager_slot_inline(uuid, uuid, jsonb) TO authenticated;

-- Upload-replace RPC using the new table and enforcing no past months
CREATE OR REPLACE FUNCTION public.replace_account_manager_slots_upload(
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
    SELECT u.user_id INTO v_manager FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(v_name) AND lower(r.list_data) IN ('qparts account manager','account manager') LIMIT 1;
    IF v_manager IS NULL THEN v_errors := array_append(v_errors, 'Unknown Account Manager: '||v_name); CONTINUE; END IF;

    v_day_off := NULLIF(rec->>'day_off','')::smallint;
    IF v_day_off IS NOT NULL AND (v_day_off < 0 OR v_day_off > 6) THEN v_errors := array_append(v_errors, 'Invalid day_off for '||v_name); END IF;

    FOR s IN 1..3 LOOP
      b_sat := COALESCE((rec->>format('saturday_s%s', s))::boolean, false);
      b_sun := COALESCE((rec->>format('sunday_s%s', s))::boolean, false);
      b_mon := COALESCE((rec->>format('monday_s%s', s))::boolean, false);
      b_tue := COALESCE((rec->>format('tuesday_s%s', s))::boolean, false);
      b_wed := COALESCE((rec->>format('wednesday_s%s', s))::boolean, false);
      b_thu := COALESCE((rec->>format('thursday_s%s', s))::boolean, false);
    END LOOP;
  END LOOP;

  IF array_length(v_errors,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_errors);
  END IF;

  DELETE FROM qvm_new_apps.account_manager_slots;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_name := trim(both from rec->>'account_manager_name');
    SELECT u.user_id INTO v_manager FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(v_name) AND lower(r.list_data) IN ('qparts account manager','account manager') LIMIT 1;

    FOR s IN 1..3 LOOP
      b_sat := COALESCE((rec->>format('saturday_s%s', s))::boolean, false);
      b_sun := COALESCE((rec->>format('sunday_s%s', s))::boolean, false);
      b_mon := COALESCE((rec->>format('monday_s%s', s))::boolean, false);
      b_tue := COALESCE((rec->>format('tuesday_s%s', s))::boolean, false);
      b_wed := COALESCE((rec->>format('wednesday_s%s', s))::boolean, false);
      b_thu := COALESCE((rec->>format('thursday_s%s', s))::boolean, false);

      INSERT INTO qvm_new_apps.account_manager_slots(account_manager, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, is_available, created_at, updated_at)
      VALUES (v_manager, s, b_sat, b_sun, b_mon, b_tue, b_wed, b_thu, true, now(), now());
      v_inserted := v_inserted + 1;
    END LOOP;

    IF p_update_weekly_dayoff THEN
      v_day_off := NULLIF(rec->>'day_off','')::smallint;
      IF v_day_off IS NOT NULL AND v_day_off BETWEEN 0 AND 6 THEN
        INSERT INTO qvm_new_apps.account_manager_weekly_daysoff(account_manager, month, day_off) VALUES (v_manager, v_m, v_day_off)
        ON CONFLICT (account_manager, month) DO UPDATE SET day_off = EXCLUDED.day_off;
        INSERT INTO qvm_new_apps.account_manager_weekly_daysoff(account_manager, month, day_off) VALUES (v_manager, v_m_next, v_day_off)
        ON CONFLICT (account_manager, month) DO UPDATE SET day_off = EXCLUDED.day_off;
      END IF;
    END IF;
  END LOOP;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status','success','inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_account_manager_slots_upload(uuid, date, boolean, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_account_manager_slots_upload(uuid, date, boolean, jsonb) TO authenticated;

COMMIT;
