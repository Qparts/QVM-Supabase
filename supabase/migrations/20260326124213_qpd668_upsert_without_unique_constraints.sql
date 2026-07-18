-- Synced from QVM/test branch applied migration history (version 20260326124213, name: qpd668_upsert_without_unique_constraints)
SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.upsert_profit_margins_bulk(
  p_user_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_updated int := 0;
  v_inserted int := 0;
  v_total int := 0;
  itm jsonb;
  v_branch_id int;
  v_brand_class int;
  v_part_category int;
  v_cost_range int;
  v_percentage numeric;
  v_cat_id int;
  v_rowcount int := 0;
BEGIN
  -- Authorization: Admin, Finance Manager, Pricing Supervisor can edit
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND lower(ur.list_data) IN ('admin','finance manager','pricing supervisor')
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

    -- ensure category exists (brand_class + part_category)
    SELECT category_id INTO v_cat_id
    FROM qvm_new_apps.profit_categories
    WHERE brand_class = v_brand_class AND part_category = v_part_category
    LIMIT 1;

    IF v_cat_id IS NULL THEN
      INSERT INTO qvm_new_apps.profit_categories(brand_class, part_category)
      VALUES(v_brand_class, v_part_category)
      RETURNING category_id INTO v_cat_id;
    END IF;

    IF v_branch_id IS NULL THEN
      -- try update global first
      UPDATE qvm_new_apps.profit_margins
         SET percentage = v_percentage, updated_at = now()
       WHERE profit_categories_id = v_cat_id AND cost_range_id = v_cost_range;
      GET DIAGNOSTICS v_rowcount = ROW_COUNT;
      IF v_rowcount = 0 THEN
        INSERT INTO qvm_new_apps.profit_margins (profit_categories_id, cost_range_id, percentage)
        VALUES (v_cat_id, v_cost_range, v_percentage);
        v_inserted := v_inserted + 1;
      ELSE
        v_updated := v_updated + v_rowcount;
      END IF;
    ELSE
      -- try update branch override first
      UPDATE qvm_new_apps.profit_margins_branch
         SET percentage = v_percentage, updated_at = now(), updated_by = p_user_id
       WHERE branch_id = v_branch_id AND profit_categories_id = v_cat_id AND cost_range_id = v_cost_range;
      GET DIAGNOSTICS v_rowcount = ROW_COUNT;
      IF v_rowcount = 0 THEN
        INSERT INTO qvm_new_apps.profit_margins_branch (branch_id, profit_categories_id, cost_range_id, percentage, created_by, updated_by)
        VALUES (v_branch_id, v_cat_id, v_cost_range, v_percentage, p_user_id, p_user_id);
        v_inserted := v_inserted + 1;
      ELSE
        v_updated := v_updated + v_rowcount;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','success','processed', v_total, 'updated', v_updated, 'inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb) TO authenticated;;
