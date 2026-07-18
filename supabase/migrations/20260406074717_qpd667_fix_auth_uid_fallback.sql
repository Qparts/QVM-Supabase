-- Synced from QVM/test branch applied migration history (version 20260406074717, name: qpd667_fix_auth_uid_fallback)
-- QPD-667: Use auth.uid() fallback for user identity in upsert_profit_margins_bulk
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.upsert_profit_margins_bulk(
  p_user_id uuid,
  p_items jsonb,
  p_method text DEFAULT 'inline'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_uid uuid := COALESCE(p_user_id, auth.uid());
  v_allowed boolean;
  v_updated int := 0;
  v_total int := 0;
  v_last_affected int := 0;
  itm jsonb;
  v_branch_id int;
  v_brand_class int;
  v_part_category int;
  v_cost_range int;
  v_percentage numeric;
  v_cat_id int;
  v_old numeric;
BEGIN
  -- Authorization: allow Admin, Finance Manager, Pricing Supervisor, or Internal (user_type=185)
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Invalid payload';
  END IF;

  FOR itm IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_total := v_total + 1;
    v_branch_id := NULLIF((itm->>'branch_id')::int, 0);
    v_brand_class := (itm->>'brand_class_id')::int;
    v_part_category := (itm->>'part_category_id')::int;
    v_cost_range := (itm->>'cost_range_id')::int;
    v_percentage := (itm->>'percentage')::numeric;

    IF v_percentage IS NULL OR v_percentage < 0 OR v_percentage > 100 THEN
      RAISE EXCEPTION 'Invalid percentage';
    END IF;

    SELECT category_id INTO v_cat_id
    FROM qvm_new_apps.profit_categories
    WHERE brand_class = v_brand_class AND part_category = v_part_category
    LIMIT 1;

    IF v_cat_id IS NULL THEN
      INSERT INTO qvm_new_apps.profit_categories(brand_class, part_category)
      VALUES(v_brand_class, v_part_category)
      ON CONFLICT (brand_class, part_category) DO UPDATE SET brand_class = EXCLUDED.brand_class
      RETURNING category_id INTO v_cat_id;
    END IF;

    IF v_branch_id IS NULL THEN
      SELECT percentage INTO v_old
      FROM qvm_new_apps.profit_margins
      WHERE profit_categories_id = v_cat_id AND cost_range_id = v_cost_range;

      INSERT INTO qvm_new_apps.profit_margins (profit_categories_id, cost_range_id, percentage)
      VALUES (v_cat_id, v_cost_range, v_percentage)
      ON CONFLICT (profit_categories_id, cost_range_id)
      DO UPDATE SET percentage = EXCLUDED.percentage, updated_at = now();
      GET DIAGNOSTICS v_last_affected = ROW_COUNT;
      v_updated := v_updated + v_last_affected;

      IF COALESCE(v_old, -999999) IS DISTINCT FROM v_percentage THEN
        INSERT INTO qvm_new_apps.profit_margins_audit(method, user_id, branch_id, profit_categories_id, cost_range_id, old_percentage, new_percentage, updated_at)
        VALUES (COALESCE(NULLIF(lower(p_method),''),'inline'), v_uid, NULL, v_cat_id, v_cost_range, v_old, v_percentage, now());
      END IF;
    ELSE
      SELECT percentage INTO v_old
      FROM qvm_new_apps.profit_margins_branch
      WHERE branch_id = v_branch_id AND profit_categories_id = v_cat_id AND cost_range_id = v_cost_range;

      INSERT INTO qvm_new_apps.profit_margins_branch (branch_id, profit_categories_id, cost_range_id, percentage, created_by, updated_by)
      VALUES (v_branch_id, v_cat_id, v_cost_range, v_percentage, v_uid, v_uid)
      ON CONFLICT (branch_id, profit_categories_id, cost_range_id)
      DO UPDATE SET percentage = EXCLUDED.percentage, updated_at = now(), updated_by = EXCLUDED.updated_by;
      GET DIAGNOSTICS v_last_affected = ROW_COUNT;
      v_updated := v_updated + v_last_affected;

      IF COALESCE(v_old, -999999) IS DISTINCT FROM v_percentage THEN
        INSERT INTO qvm_new_apps.profit_margins_audit(method, user_id, branch_id, profit_categories_id, cost_range_id, old_percentage, new_percentage, updated_at)
        VALUES (COALESCE(NULLIF(lower(p_method),''),'inline'), v_uid, v_branch_id, v_cat_id, v_cost_range, v_old, v_percentage, now());
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','success', 'processed', v_total, 'updated', v_updated);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb, text) TO authenticated;

COMMIT;;
