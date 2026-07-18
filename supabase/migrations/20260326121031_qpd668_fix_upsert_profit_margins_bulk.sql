-- Synced from QVM/test branch applied migration history (version 20260326121031, name: qpd668_fix_upsert_profit_margins_bulk)
SET search_path TO qvm_new_apps, public;

-- Ensure filters RPC exists
CREATE OR REPLACE FUNCTION public.list_profit_filters()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_clients jsonb;
  v_branches jsonb;
  v_brand_classes jsonb;
  v_part_categories jsonb;
  v_price_categories jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg((SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x) ORDER BY name), '[]'::jsonb)
  INTO v_clients
  FROM (
    SELECT DISTINCT cb.list_data_id
    FROM qvm_new_apps.client_branches cb
    WHERE cb.list_data_id IS NOT NULL
  ) s
  JOIN qvm_new_apps.list_data ld ON ld.list_data_id = s.list_data_id;

  SELECT COALESCE(jsonb_agg((SELECT x FROM (SELECT cb.customer_id AS id, cb.branch_name AS name, cb.list_data_id AS client_id) x) ORDER BY name), '[]'::jsonb)
  INTO v_branches
  FROM qvm_new_apps.client_branches cb
  WHERE cb.customer_id IS NOT NULL;

  SELECT COALESCE(jsonb_agg((SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x) ORDER BY name), '[]'::jsonb)
  INTO v_brand_classes
  FROM qvm_new_apps.list_data ld
  WHERE ld.list_data IN ('Genuine','OEM','Aftermarket','Used');

  SELECT COALESCE(jsonb_agg((SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x) ORDER BY name), '[]'::jsonb)
  INTO v_part_categories
  FROM qvm_new_apps.list_data ld
  WHERE ld.list_data IN ('Oil','Filter','Body','Mech/Elec','Accessories','Others');

  SELECT COALESCE(jsonb_agg((
    SELECT x FROM (
      SELECT cc.cost_range_id AS id,
             ((cc.cost_range->>0)::numeric || ' - ' || (cc.cost_range->>1)::numeric) AS name,
             cc.cost_range
    ) x) ORDER BY (cc.cost_range->>0)::numeric
  ), '[]'::jsonb)
  INTO v_price_categories
  FROM qvm_new_apps.cost_categories cc;

  RETURN jsonb_build_object(
    'clients', v_clients,
    'branches', v_branches,
    'brand_classes', v_brand_classes,
    'part_categories', v_part_categories,
    'price_categories', v_price_categories
  );
END;
$$;

REVOKE ALL ON FUNCTION public.list_profit_filters() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_profit_filters() TO authenticated;

-- Ensure matrix RPC exists
CREATE OR REPLACE FUNCTION public.get_profit_matrix(
  p_user_id uuid,
  p_client_ids int[] DEFAULT NULL,
  p_branch_ids int[] DEFAULT NULL,
  p_brand_class_ids int[] DEFAULT NULL,
  p_part_category_ids int[] DEFAULT NULL,
  p_price_range_ids int[] DEFAULT NULL,
  p_search text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  rows jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  WITH 
  bc AS (
    SELECT ld.list_data_id AS id, ld.list_data AS name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data IN ('Genuine','OEM','Aftermarket','Used')
      AND (p_brand_class_ids IS NULL OR ld.list_data_id = ANY(p_brand_class_ids))
  ),
  pc AS (
    SELECT ld.list_data_id AS id, ld.list_data AS name
    FROM qvm_new_apps.list_data ld
    WHERE ld.list_data IN ('Oil','Filter','Body','Mech/Elec','Accessories','Others')
      AND (p_part_category_ids IS NULL OR ld.list_data_id = ANY(p_part_category_ids))
  ),
  pr AS (
    SELECT cc.cost_range_id AS id,
           ((cc.cost_range->>0)::numeric) AS low,
           ((cc.cost_range->>1)::numeric) AS high,
           ((cc.cost_range->>0) || ' - ' || (cc.cost_range->>1)) AS label
    FROM qvm_new_apps.cost_categories cc
    WHERE (p_price_range_ids IS NULL OR cc.cost_range_id = ANY(p_price_range_ids))
  ),
  br AS (
    SELECT cb.customer_id AS id, cb.branch_name AS name, cb.list_data_id AS client_id
    FROM qvm_new_apps.client_branches cb
    WHERE (p_branch_ids IS NULL OR cb.customer_id = ANY(p_branch_ids))
      AND (p_client_ids IS NULL OR cb.list_data_id = ANY(p_client_ids))
      AND (p_search IS NULL OR POSITION(lower(p_search) in lower(COALESCE(cb.branch_name,''))) > 0)
  ),
  combos AS (
    SELECT br.id AS branch_id, br.name AS branch_name, br.client_id,
           bc.id AS brand_class_id, bc.name AS brand_class_name,
           pc.id AS part_category_id, pc.name AS part_category_name,
           pr.id AS cost_range_id, pr.label AS cost_range_label
    FROM br
    CROSS JOIN bc
    CROSS JOIN pc
    CROSS JOIN pr
  ),
  cats AS (
    SELECT pc.category_id, pc.brand_class, pc.part_category
    FROM qvm_new_apps.profit_categories pc
  ),
  resolved AS (
    SELECT c.branch_id, c.branch_name, c.client_id,
           c.brand_class_id, c.brand_class_name,
           c.part_category_id, c.part_category_name,
           c.cost_range_id, c.cost_range_label,
           COALESCE(pmb.percentage, pm.percentage) AS percentage,
           CASE WHEN pmb.percentage IS NOT NULL THEN 'branch' ELSE CASE WHEN pm.percentage IS NOT NULL THEN 'global' ELSE NULL END END AS source
    FROM combos c
    LEFT JOIN cats ct ON ct.brand_class = c.brand_class_id AND ct.part_category = c.part_category_id
    LEFT JOIN qvm_new_apps.profit_margins_branch pmb
      ON pmb.branch_id = c.branch_id
     AND pmb.profit_categories_id = ct.category_id
     AND pmb.cost_range_id = c.cost_range_id
    LEFT JOIN qvm_new_apps.profit_margins pm
      ON pm.profit_categories_id = ct.category_id
     AND pm.cost_range_id = c.cost_range_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.part_category_name, r.branch_name, r.brand_class_name, r.cost_range_id), '[]'::jsonb)
  INTO rows
  FROM resolved r;

  RETURN jsonb_build_object('rows', rows);
END;
$$;

REVOKE ALL ON FUNCTION public.get_profit_matrix(uuid, int[], int[], int[], int[], int[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_profit_matrix(uuid, int[], int[], int[], int[], int[], text) TO authenticated;

-- Fix upsert RPC: correct GET DIAGNOSTICS usage
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
      INSERT INTO qvm_new_apps.profit_margins (profit_categories_id, cost_range_id, percentage)
      VALUES (v_cat_id, v_cost_range, v_percentage)
      ON CONFLICT (profit_categories_id, cost_range_id)
      DO UPDATE SET percentage = EXCLUDED.percentage, updated_at = now();
      GET DIAGNOSTICS v_rowcount = ROW_COUNT;
      v_updated := v_updated + v_rowcount;
    ELSE
      INSERT INTO qvm_new_apps.profit_margins_branch (branch_id, profit_categories_id, cost_range_id, percentage, created_by, updated_by)
      VALUES (v_branch_id, v_cat_id, v_cost_range, v_percentage, p_user_id, p_user_id)
      ON CONFLICT (branch_id, profit_categories_id, cost_range_id)
      DO UPDATE SET percentage = EXCLUDED.percentage, updated_at = now(), updated_by = EXCLUDED.updated_by;
      GET DIAGNOSTICS v_rowcount = ROW_COUNT;
      v_updated := v_updated + v_rowcount;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','success','processed', v_total, 'updated', v_updated);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_profit_margins_bulk(uuid, jsonb) TO authenticated;;
