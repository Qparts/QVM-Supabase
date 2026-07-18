-- Synced from QVM/test branch applied migration history (version 20260326121816, name: qpd668_auth_update_get_profit_matrix)
SET search_path TO qvm_new_apps, public;

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
  -- Authorization: allow Internal users (user_type=185) OR certain role labels
  IF NOT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185 OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
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
GRANT EXECUTE ON FUNCTION public.get_profit_matrix(uuid, int[], int[], int[], int[], int[], text) TO authenticated;;
