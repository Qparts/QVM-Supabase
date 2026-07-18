-- Synced from QVM/test branch applied migration history (version 20260602122429, name: qpd_fix_branch_bulk_upsert_without_conflict_constraint)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.upsert_account_manager_branches_bulk(
  p_user_id uuid,
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
  rec jsonb;
  b_id int;
  m1 uuid; m2 uuid; m3 uuid;
  s11 uuid; s12 uuid; s13 uuid;
  s21 uuid; s22 uuid; s23 uuid;
  fb uuid;
  manager_count int;
  v_row_id bigint;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('qparts admin','pricing supervisor','admin')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Invalid rows payload';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    b_id := NULLIF(rec->>'branch_id', '')::int;
    IF b_id IS NULL THEN
      v_errors := array_append(v_errors, 'Row missing branch_id');
      CONTINUE;
    END IF;

    m1 := NULLIF(rec->>'main_s1','')::uuid;
    m2 := NULLIF(rec->>'main_s2','')::uuid;
    m3 := NULLIF(rec->>'main_s3','')::uuid;
    s11 := NULLIF(rec->>'sub1_s1','')::uuid;
    s12 := NULLIF(rec->>'sub1_s2','')::uuid;
    s13 := NULLIF(rec->>'sub1_s3','')::uuid;
    s21 := NULLIF(rec->>'sub2_s1','')::uuid;
    s22 := NULLIF(rec->>'sub2_s2','')::uuid;
    s23 := NULLIF(rec->>'sub2_s3','')::uuid;
    fb := NULLIF(rec->>'fallback_user','')::uuid;

    SELECT COUNT(*)
    INTO manager_count
    FROM qvm_new_apps.user_data u
    WHERE u.user_id IN (
      m1, m2, m3,
      s11, s12, s13,
      s21, s22, s23,
      fb
    );

    IF manager_count < COALESCE((rec->>'non_null_count')::int, 0) THEN
      v_errors := array_append(v_errors, 'One or more account manager IDs are invalid for branch ' || b_id);
    END IF;
  END LOOP;

  IF array_length(v_errors, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'error', 'errors', v_errors);
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    b_id := NULLIF(rec->>'branch_id', '')::int;
    m1 := NULLIF(rec->>'main_s1','')::uuid;
    m2 := NULLIF(rec->>'main_s2','')::uuid;
    m3 := NULLIF(rec->>'main_s3','')::uuid;
    s11 := NULLIF(rec->>'sub1_s1','')::uuid;
    s12 := NULLIF(rec->>'sub1_s2','')::uuid;
    s13 := NULLIF(rec->>'sub1_s3','')::uuid;
    s21 := NULLIF(rec->>'sub2_s1','')::uuid;
    s22 := NULLIF(rec->>'sub2_s2','')::uuid;
    s23 := NULLIF(rec->>'sub2_s3','')::uuid;
    fb := NULLIF(rec->>'fallback_user','')::uuid;

    SELECT id INTO v_row_id
    FROM qvm_new_apps.account_manager_branches
    WHERE customer_id = b_id AND slot_number = 1
    LIMIT 1;
    IF v_row_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(
        customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager, created_at, updated_at
      ) VALUES (b_id, 1, m1, s11, s21, fb, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET
        main_account_manager = m1,
        first_substitute = s11,
        second_substitute = s21,
        fallback_account_manager = fb,
        updated_at = now()
      WHERE id = v_row_id;
    END IF;

    SELECT id INTO v_row_id
    FROM qvm_new_apps.account_manager_branches
    WHERE customer_id = b_id AND slot_number = 2
    LIMIT 1;
    IF v_row_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(
        customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager, created_at, updated_at
      ) VALUES (b_id, 2, m2, s12, s22, fb, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET
        main_account_manager = m2,
        first_substitute = s12,
        second_substitute = s22,
        fallback_account_manager = fb,
        updated_at = now()
      WHERE id = v_row_id;
    END IF;

    SELECT id INTO v_row_id
    FROM qvm_new_apps.account_manager_branches
    WHERE customer_id = b_id AND slot_number = 3
    LIMIT 1;
    IF v_row_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(
        customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager, created_at, updated_at
      ) VALUES (b_id, 3, m3, s13, s23, fb, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET
        main_account_manager = m3,
        first_substitute = s13,
        second_substitute = s23,
        fallback_account_manager = fb,
        updated_at = now()
      WHERE id = v_row_id;
    END IF;

    v_processed := v_processed + 1;
  END LOOP;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status', 'success', 'processed', v_processed);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_account_manager_branches_bulk(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_account_manager_branches_bulk(uuid, jsonb) TO authenticated;

COMMIT;;
