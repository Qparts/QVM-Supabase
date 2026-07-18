-- Synced from QVM/test branch applied migration history (version 20260406071616, name: qpd667_profit_audit_and_rpc_v2)
-- QPD-667/674: Profit margins audit logging + validations + method flag (fixed GET DIAGNOSTICS)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE TABLE IF NOT EXISTS qvm_new_apps.profit_margins_audit (
  audit_id BIGSERIAL PRIMARY KEY,
  method text NOT NULL CHECK (method IN ('inline','bulk')),
  user_id uuid NOT NULL,
  branch_id int NULL,
  profit_categories_id int NOT NULL,
  cost_range_id int NOT NULL,
  old_percentage numeric NULL,
  new_percentage numeric NOT NULL,
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pma_branch ON qvm_new_apps.profit_margins_audit(branch_id);
CREATE INDEX IF NOT EXISTS idx_pma_cat ON qvm_new_apps.profit_margins_audit(profit_categories_id, cost_range_id);
CREATE INDEX IF NOT EXISTS idx_pma_user ON qvm_new_apps.profit_margins_audit(user_id);

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
        VALUES (COALESCE(NULLIF(lower(p_method),''),'inline'), p_user_id, NULL, v_cat_id, v_cost_range, v_old, v_percentage, now());
      END IF;
    ELSE
      SELECT percentage INTO v_old
      FROM qvm_new_apps.profit_margins_branch
      WHERE branch_id = v_branch_id AND profit_categories_id = v_cat_id AND cost_range_id = v_cost_range;

      INSERT INTO qvm_new_apps.profit_margins_branch (branch_id, profit_categories_id, cost_range_id, percentage, created_by, updated_by)
      VALUES (v_branch_id, v_cat_id, v_cost_range, v_percentage, p_user_id, p_user_id)
      ON CONFLICT (branch_id, profit_categories_id, cost_range_id)
      DO UPDATE SET percentage = EXCLUDED.percentage, updated_at = now(), updated_by = EXCLUDED.updated_by;
      GET DIAGNOSTICS v_last_affected = ROW_COUNT;
      v_updated := v_updated + v_last_affected;

      IF COALESCE(v_old, -999999) IS DISTINCT FROM v_percentage THEN
        INSERT INTO qvm_new_apps.profit_margins_audit(method, user_id, branch_id, profit_categories_id, cost_range_id, old_percentage, new_percentage, updated_at)
        VALUES (COALESCE(NULLIF(lower(p_method),''),'inline'), p_user_id, v_branch_id, v_cat_id, v_cost_range, v_old, v_percentage, now());
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','success', 'processed', v_total, 'updated', v_updated);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb, text) TO authenticated;

COMMIT;;
