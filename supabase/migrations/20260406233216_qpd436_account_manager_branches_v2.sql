-- Synced from QVM/test branch applied migration history (version 20260406233216, name: qpd436_account_manager_branches_v2)
BEGIN;

SET search_path TO qvm_new_apps, public;

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

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.branch_name,
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
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.account_manager_branches amb ON amb.branch_id = cb.customer_id
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

CREATE OR REPLACE FUNCTION public.replace_account_manager_branches_by_names(
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
  b_name text;
  b_id int;
  m1 text; m2 text; m3 text;
  s11 text; s12 text; s13 text;
  s21 text; s22 text; s23 text;
  fb text;
  um1 uuid; um2 uuid; um3 uuid;
  us11 uuid; us12 uuid; us13 uuid;
  us21 uuid; us22 uuid; us23 uuid;
  ufb uuid;
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
    b_name := NULLIF(trim(both from rec->>'branch_name'), '');
    IF b_name IS NULL THEN
      v_errors := array_append(v_errors, 'Row missing Branch Name');
      CONTINUE;
    END IF;
    SELECT cb.customer_id INTO b_id FROM qvm_new_apps.client_branches cb WHERE lower(trim(cb.branch_name)) = lower(b_name) LIMIT 1;
    IF b_id IS NULL THEN
      v_errors := array_append(v_errors, 'Unknown Branch Name: '||b_name);
      CONTINUE;
    END IF;

    m1 := NULLIF(trim(both from rec->>'main_s1'), '');
    m2 := NULLIF(trim(both from rec->>'main_s2'), '');
    m3 := NULLIF(trim(both from rec->>'main_s3'), '');
    s11 := NULLIF(trim(both from rec->>'sub1_s1'), '');
    s12 := NULLIF(trim(both from rec->>'sub1_s2'), '');
    s13 := NULLIF(trim(both from rec->>'sub1_s3'), '');
    s21 := NULLIF(trim(both from rec->>'sub2_s1'), '');
    s22 := NULLIF(trim(both from rec->>'sub2_s2'), '');
    s23 := NULLIF(trim(both from rec->>'sub2_s3'), '');
    fb  := NULLIF(trim(both from rec->>'fallback_user'), '');

    IF m1 IS NOT NULL THEN SELECT u.user_id INTO um1 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m1) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF m2 IS NOT NULL THEN SELECT u.user_id INTO um2 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m2) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF m3 IS NOT NULL THEN SELECT u.user_id INTO um3 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m3) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s11 IS NOT NULL THEN SELECT u.user_id INTO us11 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s11) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s12 IS NOT NULL THEN SELECT u.user_id INTO us12 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s12) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s13 IS NOT NULL THEN SELECT u.user_id INTO us13 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s13) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s21 IS NOT NULL THEN SELECT u.user_id INTO us21 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s21) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s22 IS NOT NULL THEN SELECT u.user_id INTO us22 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s22) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s23 IS NOT NULL THEN SELECT u.user_id INTO us23 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s23) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF fb  IS NOT NULL THEN SELECT u.user_id INTO ufb  FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(fb)  AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;

    IF m1 IS NOT NULL AND um1 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for Main S1 in branch '||b_name||': '||m1); END IF;
    IF m2 IS NOT NULL AND um2 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for Main S2 in branch '||b_name||': '||m2); END IF;
    IF m3 IS NOT NULL AND um3 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for Main S3 in branch '||b_name||': '||m3); END IF;
    IF s11 IS NOT NULL AND us11 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 1st Sub S1 in branch '||b_name||': '||s11); END IF;
    IF s12 IS NOT NULL AND us12 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 1st Sub S2 in branch '||b_name||': '||s12); END IF;
    IF s13 IS NOT NULL AND us13 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 1st Sub S3 in branch '||b_name||': '||s13); END IF;
    IF s21 IS NOT NULL AND us21 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 2nd Sub S1 in branch '||b_name||': '||s21); END IF;
    IF s22 IS NOT NULL AND us22 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 2nd Sub S2 in branch '||b_name||': '||s22); END IF;
    IF s23 IS NOT NULL AND us23 IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for 2nd Sub S3 in branch '||b_name||': '||s23); END IF;
    IF fb  IS NOT NULL AND ufb  IS NULL THEN v_errors := array_append(v_errors, 'Unknown manager for Fallback in branch '||b_name||': '||fb); END IF;
  END LOOP;

  IF array_length(v_errors,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','error','errors', v_errors);
  END IF;

  DELETE FROM qvm_new_apps.account_manager_branches;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    b_name := NULLIF(trim(both from rec->>'branch_name'), '');
    SELECT cb.customer_id INTO b_id FROM qvm_new_apps.client_branches cb WHERE lower(trim(cb.branch_name)) = lower(b_name) LIMIT 1;

    m1 := NULLIF(trim(both from rec->>'main_s1'), '');
    m2 := NULLIF(trim(both from rec->>'main_s2'), '');
    m3 := NULLIF(trim(both from rec->>'main_s3'), '');
    s11 := NULLIF(trim(both from rec->>'sub1_s1'), '');
    s12 := NULLIF(trim(both from rec->>'sub1_s2'), '');
    s13 := NULLIF(trim(both from rec->>'sub1_s3'), '');
    s21 := NULLIF(trim(both from rec->>'sub2_s1'), '');
    s22 := NULLIF(trim(both from rec->>'sub2_s2'), '');
    s23 := NULLIF(trim(both from rec->>'sub2_s3'), '');
    fb  := NULLIF(trim(both from rec->>'fallback_user'), '');

    um1 := NULL; um2 := NULL; um3 := NULL; us11 := NULL; us12 := NULL; us13 := NULL; us21 := NULL; us22 := NULL; us23 := NULL; ufb := NULL;
    IF m1 IS NOT NULL THEN SELECT u.user_id INTO um1 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m1) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF m2 IS NOT NULL THEN SELECT u.user_id INTO um2 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m2) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF m3 IS NOT NULL THEN SELECT u.user_id INTO um3 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(m3) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s11 IS NOT NULL THEN SELECT u.user_id INTO us11 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s11) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s12 IS NOT NULL THEN SELECT u.user_id INTO us12 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s12) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s13 IS NOT NULL THEN SELECT u.user_id INTO us13 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s13) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s21 IS NOT NULL THEN SELECT u.user_id INTO us21 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s21) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s22 IS NOT NULL THEN SELECT u.user_id INTO us22 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s22) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF s23 IS NOT NULL THEN SELECT u.user_id INTO us23 FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(s23) AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;
    IF fb  IS NOT NULL THEN SELECT u.user_id INTO ufb  FROM qvm_new_apps.user_data u LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role WHERE lower(u.user_name) = lower(fb)  AND lower(r.list_data) IN ('account manager') LIMIT 1; END IF;

    INSERT INTO qvm_new_apps.account_manager_branches(
      branch_id, main_s1, main_s2, main_s3,
      sub1_s1, sub1_s2, sub1_s3,
      sub2_s1, sub2_s2, sub2_s3,
      fallback_user, created_at, updated_at
    ) VALUES (
      b_id, um1, um2, um3, us11, us12, us13, us21, us22, us23, ufb, now(), now()
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

  PERFORM public.recalculate_account_manager_allocations();

  RETURN jsonb_build_object('status','success','inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_account_manager_branches_by_names(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_account_manager_branches_by_names(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.recalculate_account_manager_allocations()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
BEGIN
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_account_manager_allocations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalculate_account_manager_allocations() TO authenticated;

COMMIT;;
