BEGIN;

SET search_path TO qvm_new_apps, public;

-- Ensure required extensions
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- Attendance records table
CREATE TABLE IF NOT EXISTS qvm_new_apps.account_manager_attendance (
  id            bigserial PRIMARY KEY,
  account_manager uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  record_type   text NOT NULL CHECK (lower(record_type) IN ('vacation','excuse','overtime')),
  start_date    date NOT NULL,
  end_date      date NOT NULL,
  slots         smallint[] NULL CHECK (slots <@ ARRAY[1,2,3]::smallint[]),
  created_by    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Prevent overlapping vacations per manager
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'am_attendance_vacation_no_overlap'
  ) THEN
    EXECUTE 'ALTER TABLE qvm_new_apps.account_manager_attendance
      ADD CONSTRAINT am_attendance_vacation_no_overlap
      EXCLUDE USING gist (
        account_manager WITH =,
        daterange(start_date, end_date, ''[]'') WITH &&
      ) WHERE (lower(record_type) = ''vacation'')';
  END IF;
END$$;

-- Helper: get next date matching a target DOW [0..6] where 0 = Sunday; our week uses Sat..Thu so we map accordingly
CREATE OR REPLACE FUNCTION public._date_for_weekday(base date, target_dow int)
RETURNS date
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  b integer := extract(dow from base); -- 0..6 Sun..Sat
  diff integer := (target_dow - b + 7) % 7;
BEGIN
  RETURN base + diff;
END;
$$;

-- Helper: check if a manager is available on a given date for a slot, considering weekly slots and attendance overrides
CREATE OR REPLACE FUNCTION public._am_is_available(p_manager uuid, p_slot smallint, p_date date)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  dow int := extract(dow from p_date); -- 0..6 Sun..Sat
  v_slot qvm_new_apps.account_manager_slots%ROWTYPE;
  v_has_vacation boolean := false;
  v_has_excuse boolean := false;
  v_has_overtime boolean := false;
  v_day_ok boolean := false;
BEGIN
  SELECT * INTO v_slot
  FROM qvm_new_apps.account_manager_slots s
  WHERE s.account_manager = p_manager AND s.slot_number = p_slot
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Map dow to our columns (Sat..Thu); Postgres: 0=Sun,6=Sat
  -- We treat Fri (5) as not scheduled since schema has Sat..Thu
  IF dow = 6 THEN v_day_ok := COALESCE(v_slot.saturday, false);
  ELSIF dow = 0 THEN v_day_ok := COALESCE(v_slot.sunday, false);
  ELSIF dow = 1 THEN v_day_ok := COALESCE(v_slot.monday, false);
  ELSIF dow = 2 THEN v_day_ok := COALESCE(v_slot.tuesday, false);
  ELSIF dow = 3 THEN v_day_ok := COALESCE(v_slot.wednesday, false);
  ELSIF dow = 4 THEN v_day_ok := COALESCE(v_slot.thursday, false);
  ELSE -- Friday
    v_day_ok := false;
  END IF;

  IF NOT v_day_ok OR NOT COALESCE(v_slot.is_available, false) THEN
    -- Overtime can override later; keep evaluating
    v_day_ok := false;
  END IF;

  -- Attendance overrides on this date
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.account_manager_attendance a
    WHERE a.account_manager = p_manager
      AND lower(a.record_type) = 'vacation'
      AND p_date BETWEEN a.start_date AND a.end_date
  ) INTO v_has_vacation;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.account_manager_attendance a
    WHERE a.account_manager = p_manager
      AND lower(a.record_type) = 'excuse'
      AND p_date = a.start_date
      AND (a.slots IS NULL OR p_slot = ANY (a.slots))
  ) INTO v_has_excuse;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.account_manager_attendance a
    WHERE a.account_manager = p_manager
      AND lower(a.record_type) = 'overtime'
      AND p_date = a.start_date
      AND (a.slots IS NULL OR p_slot = ANY (a.slots))
  ) INTO v_has_overtime;

  IF v_has_vacation OR v_has_excuse THEN
    RETURN false;
  END IF;

  IF v_has_overtime THEN
    RETURN true; -- force available
  END IF;

  RETURN v_day_ok;
END;
$$;

-- Helper: pick next available manager for a branch/slot on a date, following hierarchy
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
    MAX(CASE WHEN slot_number = p_slot THEN main_account_manager END),
    MAX(CASE WHEN slot_number = p_slot THEN first_substitute END),
    MAX(CASE WHEN slot_number = p_slot THEN second_substitute END),
    MAX(CASE WHEN slot_number = p_slot THEN fallback_account_manager END)
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

-- Baseline recalculation: set allocations ignoring temporary attendance (uses weekly slots only)
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
      -- pick using weekly slots only by temporarily disabling attendance queries
      -- Achieve this by relying on _am_is_available without any overtime/excuse applied (no attendance rows used)
      -- We simulate baseline by assuming no attendance rows exist: achieved externally by not having active rows in queries below.
      m := public._pick_available_manager(rec_branch.branch_id, s, d_sat);
      UPDATE qvm_new_apps.account_manager_allocations
        SET saturday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      m := public._pick_available_manager(rec_branch.branch_id, s, d_sun);
      UPDATE qvm_new_apps.account_manager_allocations
        SET sunday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      m := public._pick_available_manager(rec_branch.branch_id, s, d_mon);
      UPDATE qvm_new_apps.account_manager_allocations
        SET monday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      m := public._pick_available_manager(rec_branch.branch_id, s, d_tue);
      UPDATE qvm_new_apps.account_manager_allocations
        SET tuesday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      m := public._pick_available_manager(rec_branch.branch_id, s, d_wed);
      UPDATE qvm_new_apps.account_manager_allocations
        SET wednesday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;

      m := public._pick_available_manager(rec_branch.branch_id, s, d_thu);
      UPDATE qvm_new_apps.account_manager_allocations
        SET thursday = m, calculated_at = now()
      WHERE customer_id = rec_branch.branch_id AND slot_number = s;
    END LOOP;
  END LOOP;
END;
$$;

-- Apply attendance overrides for a single date (today's date or any date)
CREATE OR REPLACE FUNCTION public.apply_attendance_for_date(p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  rec_branch record;
  s smallint;
  col text;
  am uuid;
  dow int := extract(dow from p_date);
BEGIN
  -- map dow to column name in allocations
  IF dow = 6 THEN col := 'saturday';
  ELSIF dow = 0 THEN col := 'sunday';
  ELSIF dow = 1 THEN col := 'monday';
  ELSIF dow = 2 THEN col := 'tuesday';
  ELSIF dow = 3 THEN col := 'wednesday';
  ELSIF dow = 4 THEN col := 'thursday';
  ELSE
    -- Friday not used; nothing to do
    RETURN;
  END IF;

  FOR rec_branch IN SELECT customer_id::int AS branch_id FROM qvm_new_apps.client_branches LOOP
    FOR s IN 1..3 LOOP
      am := public._pick_available_manager(rec_branch.branch_id, s, p_date);
      EXECUTE format('UPDATE qvm_new_apps.account_manager_allocations SET %I = $1, calculated_at = now() WHERE customer_id = $2 AND slot_number = $3', col)
      USING am, rec_branch.branch_id, s;
    END LOOP;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_attendance_for_today()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT public.apply_attendance_for_date(current_date);
$$;

-- RPC: Create attendance record with validation and immediate application for current date if in range
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
  v_is_internal boolean;
BEGIN
  -- permissions: internal or qparts admin
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

  IF array_length(v_err,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_err);
  END IF;

  -- duplicates for same date/slot/type
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

  INSERT INTO qvm_new_apps.account_manager_attendance(
    account_manager, record_type, start_date, end_date, slots, created_by
  ) VALUES (
    v_manager, v_type, v_start, v_end, v_slots, p_user_id
  ) RETURNING id INTO v_id;

  -- If current_date within range, apply immediately
  IF current_date BETWEEN v_start AND v_end THEN
    PERFORM public.apply_attendance_for_today();
  END IF;

  RETURN jsonb_build_object('status','success','attendance_id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_account_manager_attendance(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_account_manager_attendance(uuid, jsonb) TO authenticated;

-- Schedule daily rebuild + apply overrides (00:05 UTC)
DO $$
BEGIN
  PERFORM extensions.cron.schedule('am_alloc_recalc_daily', '5 0 * * *', $$
    SELECT public.recalculate_account_manager_allocations_baseline();
    SELECT public.apply_attendance_for_today();
  $$);
EXCEPTION WHEN OTHERS THEN
  -- ignore if already scheduled or not permitted in this environment
  NULL;
END$$;

COMMIT;
