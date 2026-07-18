BEGIN;

SET search_path TO qvm_new_apps, public;

-- Scope _am_is_available to attendance_record_type list
CREATE OR REPLACE FUNCTION public._am_is_available(
  p_manager uuid,
  p_slot smallint,
  p_date date
) RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  dow int := extract(dow from p_date);
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

  IF dow = 6 THEN v_day_ok := COALESCE(v_slot.saturday, false);
  ELSIF dow = 0 THEN v_day_ok := COALESCE(v_slot.sunday, false);
  ELSIF dow = 1 THEN v_day_ok := COALESCE(v_slot.monday, false);
  ELSIF dow = 2 THEN v_day_ok := COALESCE(v_slot.tuesday, false);
  ELSIF dow = 3 THEN v_day_ok := COALESCE(v_slot.wednesday, false);
  ELSIF dow = 4 THEN v_day_ok := COALESCE(v_slot.thursday, false);
  ELSE v_day_ok := false; END IF;

  IF NOT v_day_ok OR NOT COALESCE(v_slot.is_available, false) THEN
    v_day_ok := false;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.account_manager_attendance a
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = a.record_type
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE a.account_manager = p_manager
      AND lower(l.list_name) = 'attendance_record_type'
      AND lower(ld.list_data) = 'vacation'
      AND p_date BETWEEN a.start_date AND a.end_date
  ) INTO v_has_vacation;

  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.account_manager_attendance a
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = a.record_type
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE a.account_manager = p_manager
      AND lower(l.list_name) = 'attendance_record_type'
      AND lower(ld.list_data) = 'excuse'
      AND p_date = a.start_date
      AND (a.slots IS NULL OR p_slot = ANY (a.slots))
  ) INTO v_has_excuse;

  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.account_manager_attendance a
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = a.record_type
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE a.account_manager = p_manager
      AND lower(l.list_name) = 'attendance_record_type'
      AND lower(ld.list_data) = 'overtime'
      AND p_date = a.start_date
      AND (a.slots IS NULL OR p_slot = ANY (a.slots))
  ) INTO v_has_overtime;

  IF v_has_vacation OR v_has_excuse THEN
    RETURN false;
  END IF;

  IF v_has_overtime THEN
    RETURN true;
  END IF;

  RETURN v_day_ok;
END;
$$;

-- Update RPC for scoping and validation
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
  v_type_str text;
  v_type_id int;
  v_type_name text;
  v_start date;
  v_end date;
  v_slots smallint[];
  v_id bigint;
  v_err text[] := ARRAY[]::text[];
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

  v_manager := (p_payload->>'account_manager_id')::uuid;
  v_type_str := lower(trim(both from p_payload->>'record_type'));
  v_type_id := COALESCE(NULLIF(p_payload->>'record_type_id','')::int, (
    SELECT ld.list_data_id
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE lower(l.list_name) = 'attendance_record_type' AND lower(ld.list_data) = v_type_str
    LIMIT 1
  ));
  SELECT lower(ld.list_data) INTO v_type_name
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
  WHERE ld.list_data_id = v_type_id AND lower(l.list_name) = 'attendance_record_type';

  v_start := (p_payload->>'start_date')::date;
  v_end := COALESCE((p_payload->>'end_date')::date, v_start);
  v_slots := (SELECT array_agg((x)::smallint) FROM jsonb_array_elements_text(COALESCE(p_payload->'slots','[]'::jsonb)) AS t(x));

  IF v_manager IS NULL THEN v_err := array_append(v_err, 'Account Manager is required'); END IF;
  IF v_type_id IS NULL OR v_type_name NOT IN ('vacation','excuse','overtime') THEN v_err := array_append(v_err, 'Invalid record type'); END IF;
  IF v_start IS NULL THEN v_err := array_append(v_err, 'Start Date is required'); END IF;
  IF v_type_name = 'vacation' AND v_end < v_start THEN v_err := array_append(v_err, 'End Date must be on or after Start Date'); END IF;
  IF v_type_name IN ('excuse','overtime') THEN
    IF v_end IS NULL THEN v_end := v_start; END IF;
    IF v_slots IS NULL OR array_length(v_slots,1) IS NULL THEN v_err := array_append(v_err, 'Slots are required for Excuse or Overtime'); END IF;
    IF v_type_name = 'excuse' AND array_length(v_slots,1) <> 1 THEN v_err := array_append(v_err, 'Excuse must target exactly one slot'); END IF;
  END IF;

  IF array_length(v_err,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_err);
  END IF;

  IF v_type_name = 'vacation' THEN
    IF EXISTS (
      SELECT 1 FROM qvm_new_apps.account_manager_attendance a
      WHERE a.account_manager = v_manager
        AND a.record_type IN (
          SELECT ld.list_data_id
          FROM qvm_new_apps.list_data ld
          JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
          WHERE lower(l.list_name) = 'attendance_record_type' AND lower(ld.list_data) = 'vacation'
        )
        AND daterange(a.start_date, a.end_date, '[]') && daterange(v_start, v_end, '[]')
    ) THEN
      RETURN jsonb_build_object('status','error','errors', ARRAY['Overlapping vacation exists for this manager and date range.']);
    END IF;
  END IF;

  IF v_type_name IN ('excuse','overtime') THEN
    IF EXISTS (
      SELECT 1 FROM qvm_new_apps.account_manager_attendance a
      WHERE a.account_manager = v_manager
        AND a.record_type = v_type_id
        AND a.start_date = v_start AND a.end_date = v_end
        AND (a.slots && v_slots)
    ) THEN
      RETURN jsonb_build_object('status','error','errors', ARRAY['Duplicate record exists for this manager, date, and slot(s).']);
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.account_manager_attendance(
    account_manager, record_type, start_date, end_date, slots, created_by
  ) VALUES (
    v_manager, v_type_id, v_start, v_end, v_slots, p_user_id
  ) RETURNING id INTO v_id;

  IF current_date BETWEEN v_start AND v_end THEN
    PERFORM public.apply_attendance_for_today();
  END IF;

  RETURN jsonb_build_object('status','success','attendance_id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_account_manager_attendance(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_account_manager_attendance(uuid, jsonb) TO authenticated;

COMMIT;
