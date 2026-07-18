BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE TABLE IF NOT EXISTS qvm_new_apps.account_manager_branches (
  branch_id integer PRIMARY KEY,
  main_s1 uuid NULL,
  main_s2 uuid NULL,
  main_s3 uuid NULL,
  sub1_s1 uuid NULL,
  sub1_s2 uuid NULL,
  sub1_s3 uuid NULL,
  sub2_s1 uuid NULL,
  sub2_s2 uuid NULL,
  sub2_s3 uuid NULL,
  fallback_user uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.list_account_managers(
  p_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('qparts admin', 'qparts account manager')      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT u.user_id AS id, COALESCE(u.user_name, u.user_email)::text AS name
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE lower(r.list_data) IN ('qparts account manager')
  ) x;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.list_account_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_account_managers(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_account_manager_branches_dashboard(
  p_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_can_edit boolean := false;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT (
    EXISTS (
      SELECT 1
      FROM qvm_new_apps.user_data u
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_id = p_user_id
        AND (
          u.user_type = 185
          OR lower(ur.list_data) IN ('admin','pricing supervisor')
        )
    )
  ) INTO v_can_edit;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.branch_id), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      amb.branch_id,
      amb.main_s1,
      um1.user_name AS main_s1_name,
      amb.main_s2,
      um2.user_name AS main_s2_name,
      amb.main_s3,
      um3.user_name AS main_s3_name,
      amb.sub1_s1,
      u11.user_name AS sub1_s1_name,
      amb.sub1_s2,
      u12.user_name AS sub1_s2_name,
      amb.sub1_s3,
      u13.user_name AS sub1_s3_name,
      amb.sub2_s1,
      u21.user_name AS sub2_s1_name,
      amb.sub2_s2,
      u22.user_name AS sub2_s2_name,
      amb.sub2_s3,
      u23.user_name AS sub2_s3_name,
      amb.fallback_user,
      uf.user_name AS fallback_user_name
    FROM qvm_new_apps.account_manager_branches amb
    LEFT JOIN qvm_new_apps.user_data um1 ON um1.user_id = amb.main_s1
    LEFT JOIN qvm_new_apps.user_data um2 ON um2.user_id = amb.main_s2
    LEFT JOIN qvm_new_apps.user_data um3 ON um3.user_id = amb.main_s3
    LEFT JOIN qvm_new_apps.user_data u11 ON u11.user_id = amb.sub1_s1
    LEFT JOIN qvm_new_apps.user_data u12 ON u12.user_id = amb.sub1_s2
    LEFT JOIN qvm_new_apps.user_data u13 ON u13.user_id = amb.sub1_s3
    LEFT JOIN qvm_new_apps.user_data u21 ON u21.user_id = amb.sub2_s1
    LEFT JOIN qvm_new_apps.user_data u22 ON u22.user_id = amb.sub2_s2
    LEFT JOIN qvm_new_apps.user_data u23 ON u23.user_id = amb.sub2_s3
    LEFT JOIN qvm_new_apps.user_data uf  ON uf.user_id  = amb.fallback_user
  ) t;

  RETURN jsonb_build_object('can_edit', v_can_edit, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_manager_branches_dashboard(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_branches_dashboard(uuid) TO authenticated;

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
  v_existing qvm_new_apps.account_manager_branches%ROWTYPE;
  v_changed text[] := ARRAY[]::text[];
  v_new_main_s1 uuid;
  v_new_main_s2 uuid;
  v_new_main_s3 uuid;
  v_new_sub1_s1 uuid;
  v_new_sub1_s2 uuid;
  v_new_sub1_s3 uuid;
  v_new_sub2_s1 uuid;
  v_new_sub2_s2 uuid;
  v_new_sub2_s3 uuid;
  v_new_fallback uuid;
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

  SELECT * INTO v_existing FROM qvm_new_apps.account_manager_branches WHERE branch_id = p_branch_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO qvm_new_apps.account_manager_branches(branch_id) VALUES (p_branch_id)
    ON CONFLICT (branch_id) DO NOTHING;
    SELECT * INTO v_existing FROM qvm_new_apps.account_manager_branches WHERE branch_id = p_branch_id FOR UPDATE;
  END IF;

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

  IF p_changes ? 'main_s1' AND v_new_main_s1 IS DISTINCT FROM v_existing.main_s1 THEN v_changed := array_append(v_changed, 'main_s1'); END IF;
  IF p_changes ? 'main_s2' AND v_new_main_s2 IS DISTINCT FROM v_existing.main_s2 THEN v_changed := array_append(v_changed, 'main_s2'); END IF;
  IF p_changes ? 'main_s3' AND v_new_main_s3 IS DISTINCT FROM v_existing.main_s3 THEN v_changed := array_append(v_changed, 'main_s3'); END IF;
  IF p_changes ? 'sub1_s1' AND v_new_sub1_s1 IS DISTINCT FROM v_existing.sub1_s1 THEN v_changed := array_append(v_changed, 'sub1_s1'); END IF;
  IF p_changes ? 'sub1_s2' AND v_new_sub1_s2 IS DISTINCT FROM v_existing.sub1_s2 THEN v_changed := array_append(v_changed, 'sub1_s2'); END IF;
  IF p_changes ? 'sub1_s3' AND v_new_sub1_s3 IS DISTINCT FROM v_existing.sub1_s3 THEN v_changed := array_append(v_changed, 'sub1_s3'); END IF;
  IF p_changes ? 'sub2_s1' AND v_new_sub2_s1 IS DISTINCT FROM v_existing.sub2_s1 THEN v_changed := array_append(v_changed, 'sub2_s1'); END IF;
  IF p_changes ? 'sub2_s2' AND v_new_sub2_s2 IS DISTINCT FROM v_existing.sub2_s2 THEN v_changed := array_append(v_changed, 'sub2_s2'); END IF;
  IF p_changes ? 'sub2_s3' AND v_new_sub2_s3 IS DISTINCT FROM v_existing.sub2_s3 THEN v_changed := array_append(v_changed, 'sub2_s3'); END IF;
  IF p_changes ? 'fallback_user' AND v_new_fallback IS DISTINCT FROM v_existing.fallback_user THEN v_changed := array_append(v_changed, 'fallback_user'); END IF;

  UPDATE qvm_new_apps.account_manager_branches
  SET main_s1 = COALESCE(v_new_main_s1, main_s1),
      main_s2 = COALESCE(v_new_main_s2, main_s2),
      main_s3 = COALESCE(v_new_main_s3, main_s3),
      sub1_s1 = COALESCE(v_new_sub1_s1, sub1_s1),
      sub1_s2 = COALESCE(v_new_sub1_s2, sub1_s2),
      sub1_s3 = COALESCE(v_new_sub1_s3, sub1_s3),
      sub2_s1 = COALESCE(v_new_sub2_s1, sub2_s1),
      sub2_s2 = COALESCE(v_new_sub2_s2, sub2_s2),
      sub2_s3 = COALESCE(v_new_sub2_s3, sub2_s3),
      fallback_user = COALESCE(v_new_fallback, fallback_user),
      updated_at = now()
  WHERE branch_id = p_branch_id;

  RETURN jsonb_build_object('status','success','changed', v_changed);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_account_manager_branch_inline(uuid, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_account_manager_branch_inline(uuid, integer, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.replace_account_manager_branches(
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
  v_inserted int := 0;
  rec jsonb;
  b_id int;
  m1 uuid; m2 uuid; m3 uuid;
  s11 uuid; s12 uuid; s13 uuid;
  s21 uuid; s22 uuid; s23 uuid;
  fb uuid;
  manager_count int;
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

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Invalid rows payload';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    b_id := (rec->>'branch_id')::int;
    IF b_id IS NULL THEN
      v_errors := array_append(v_errors, 'Row missing branch_id');
      CONTINUE;
    END IF;
    m1 := NULLIF(rec->>'main_s1','')::uuid; m2 := NULLIF(rec->>'main_s2','')::uuid; m3 := NULLIF(rec->>'main_s3','')::uuid;
    s11 := NULLIF(rec->>'sub1_s1','')::uuid; s12 := NULLIF(rec->>'sub1_s2','')::uuid; s13 := NULLIF(rec->>'sub1_s3','')::uuid;
    s21 := NULLIF(rec->>'sub2_s1','')::uuid; s22 := NULLIF(rec->>'sub2_s2','')::uuid; s23 := NULLIF(rec->>'sub2_s3','')::uuid;
    fb := NULLIF(rec->>'fallback_user','')::uuid;

    SELECT COUNT(*) INTO manager_count FROM qvm_new_apps.user_data u WHERE u.user_id IN (m1,m2,m3,s11,s12,s13,s21,s22,s23,fb) AND u.user_id IS NOT NULL;
    IF manager_count < COALESCE((rec->>'non_null_count')::int, 0) THEN
      v_errors := array_append(v_errors, 'One or more account manager IDs are invalid for branch '||b_id);
    END IF;
  END LOOP;

  IF array_length(v_errors,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_errors);
  END IF;

  DELETE FROM qvm_new_apps.account_manager_branches;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    b_id := (rec->>'branch_id')::int;
    m1 := NULLIF(rec->>'main_s1','')::uuid; m2 := NULLIF(rec->>'main_s2','')::uuid; m3 := NULLIF(rec->>'main_s3','')::uuid;
    s11 := NULLIF(rec->>'sub1_s1','')::uuid; s12 := NULLIF(rec->>'sub1_s2','')::uuid; s13 := NULLIF(rec->>'sub1_s3','')::uuid;
    s21 := NULLIF(rec->>'sub2_s1','')::uuid; s22 := NULLIF(rec->>'sub2_s2','')::uuid; s23 := NULLIF(rec->>'sub2_s3','')::uuid;
    fb := NULLIF(rec->>'fallback_user','')::uuid;

    INSERT INTO qvm_new_apps.account_manager_branches(
      branch_id, main_s1, main_s2, main_s3,
      sub1_s1, sub1_s2, sub1_s3,
      sub2_s1, sub2_s2, sub2_s3,
      fallback_user, created_at, updated_at
    ) VALUES (
      b_id, m1, m2, m3, s11, s12, s13, s21, s22, s23, fb, now(), now()
    ) ON CONFLICT (branch_id) DO UPDATE SET
      main_s1 = EXCLUDED.main_s1,
      main_s2 = EXCLUDED.main_s2,
      main_s3 = EXCLUDED.main_s3,
      sub1_s1 = EXCLUDED.sub1_s1,
      sub1_s2 = EXCLUDED.sub1_s2,
      sub1_s3 = EXCLUDED.sub1_s3,
      sub2_s1 = EXCLUDED.sub2_s1,
      sub2_s2 = EXCLUDED.sub2_s2,
      sub2_s3 = EXCLUDED.sub2_s3,
      fallback_user = EXCLUDED.fallback_user,
      updated_at = now();
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object('status','success','inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_account_manager_branches(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_account_manager_branches(uuid, jsonb) TO authenticated;

COMMIT;
