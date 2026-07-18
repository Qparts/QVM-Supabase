-- Synced from QVM/test branch applied migration history (version 20260602115012, name: qpd_recalc_allocations_after_branch_updates)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.upsert_account_manager_branch_inline(
  p_user_id uuid,
  p_branch_id integer,
  p_changes jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_changed text[] := ARRAY[]::text[];
  v_ex_main_s1 uuid; v_ex_main_s2 uuid; v_ex_main_s3 uuid;
  v_ex_sub1_s1 uuid; v_ex_sub1_s2 uuid; v_ex_sub1_s3 uuid;
  v_ex_sub2_s1 uuid; v_ex_sub2_s2 uuid; v_ex_sub2_s3 uuid;
  v_ex_fallback uuid;
  v_new_main_s1 uuid; v_new_main_s2 uuid; v_new_main_s3 uuid;
  v_new_sub1_s1 uuid; v_new_sub1_s2 uuid; v_new_sub1_s3 uuid;
  v_new_sub2_s1 uuid; v_new_sub2_s2 uuid; v_new_sub2_s3 uuid;
  v_new_fallback uuid;
  v_found_id int;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','pricing supervisor')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT
    CAST(MAX(CASE WHEN slot_number = 1 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (second_substitute)::text END) AS uuid),
    CAST(COALESCE(
      MAX(CASE WHEN slot_number = 1 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 2 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 3 THEN (fallback_account_manager)::text END)
    ) AS uuid)
  INTO
    v_ex_main_s1, v_ex_main_s2, v_ex_main_s3,
    v_ex_sub1_s1, v_ex_sub1_s2, v_ex_sub1_s3,
    v_ex_sub2_s1, v_ex_sub2_s2, v_ex_sub2_s3,
    v_ex_fallback
  FROM qvm_new_apps.account_manager_branches
  WHERE customer_id = p_branch_id::bigint;

  v_new_main_s1 := NULLIF(p_changes->>'main_s1','')::uuid;
  v_new_main_s2 := NULLIF(p_changes->>'main_s2','')::uuid;
  v_new_main_s3 := NULLIF(p_changes->>'main_s3','')::uuid;
  v_new_sub1_s1 := NULLIF(p_changes->>'sub1_s1','')::uuid;
  v_new_sub1_s2 := NULLIF(p_changes->>'sub1_s2','')::uuid;
  v_new_sub1_s3 := NULLIF(p_changes->>'sub1_s3','')::uuid;
  v_new_sub2_s1 := NULLIF(p_changes->>'sub2_s1','')::uuid;
  v_new_sub2_s2 := NULLIF(p_changes->>'sub2_s2','')::uuid;
  v_new_sub2_s3 := NULLIF(p_changes->>'sub2_s3','')::uuid;
  v_new_fallback := NULLIF(p_changes->>'fallback_user','')::uuid;

  IF p_changes ? 'main_s1' THEN
    IF v_new_main_s1 IS DISTINCT FROM v_ex_main_s1 THEN v_changed := array_append(v_changed, 'main_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_main_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s2' THEN
    IF v_new_main_s2 IS DISTINCT FROM v_ex_main_s2 THEN v_changed := array_append(v_changed, 'main_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_main_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s3' THEN
    IF v_new_main_s3 IS DISTINCT FROM v_ex_main_s3 THEN v_changed := array_append(v_changed, 'main_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_main_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s1' THEN
    IF v_new_sub1_s1 IS DISTINCT FROM v_ex_sub1_s1 THEN v_changed := array_append(v_changed, 'sub1_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub1_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s2' THEN
    IF v_new_sub1_s2 IS DISTINCT FROM v_ex_sub1_s2 THEN v_changed := array_append(v_changed, 'sub1_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub1_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s3' THEN
    IF v_new_sub1_s3 IS DISTINCT FROM v_ex_sub1_s3 THEN v_changed := array_append(v_changed, 'sub1_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub1_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s1' THEN
    IF v_new_sub2_s1 IS DISTINCT FROM v_ex_sub2_s1 THEN v_changed := array_append(v_changed, 'sub2_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub2_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s2' THEN
    IF v_new_sub2_s2 IS DISTINCT FROM v_ex_sub2_s2 THEN v_changed := array_append(v_changed, 'sub2_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub2_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s3' THEN
    IF v_new_sub2_s3 IS DISTINCT FROM v_ex_sub2_s3 THEN v_changed := array_append(v_changed, 'sub2_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub2_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'fallback_user' THEN
    IF v_new_fallback IS DISTINCT FROM v_ex_fallback THEN v_changed := array_append(v_changed, 'fallback_user'); END IF;
    UPDATE qvm_new_apps.account_manager_branches
    SET fallback_account_manager = v_new_fallback, updated_at = now()
    WHERE customer_id = p_branch_id::bigint;
    IF NOT FOUND THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, fallback_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_fallback, now(), now());
    END IF;
  END IF;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status','success','changed', v_changed);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_account_manager_branch_inline(uuid, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_account_manager_branch_inline(uuid, integer, jsonb) TO authenticated;

COMMIT;;
