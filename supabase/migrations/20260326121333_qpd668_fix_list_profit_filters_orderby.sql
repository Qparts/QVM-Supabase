-- Synced from QVM/test branch applied migration history (version 20260326121333, name: qpd668_fix_list_profit_filters_orderby)
SET search_path TO qvm_new_apps, public;

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
  -- Clients (distinct list_data from client_branches)
  SELECT COALESCE(
           jsonb_agg(
             (SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x)
             ORDER BY ld.list_data
           ),
           '[]'::jsonb
         )
  INTO v_clients
  FROM (
    SELECT DISTINCT cb.list_data_id
    FROM qvm_new_apps.client_branches cb
    WHERE cb.list_data_id IS NOT NULL
  ) s
  JOIN qvm_new_apps.list_data ld ON ld.list_data_id = s.list_data_id;

  -- Branches
  SELECT COALESCE(
           jsonb_agg(
             (SELECT x FROM (SELECT cb.customer_id AS id, cb.branch_name AS name, cb.list_data_id AS client_id) x)
             ORDER BY cb.branch_name
           ),
           '[]'::jsonb
         )
  INTO v_branches
  FROM qvm_new_apps.client_branches cb
  WHERE cb.customer_id IS NOT NULL;

  -- Brand classes (expected four)
  SELECT COALESCE(
           jsonb_agg(
             (SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x)
             ORDER BY ld.list_data
           ),
           '[]'::jsonb
         )
  INTO v_brand_classes
  FROM qvm_new_apps.list_data ld
  WHERE ld.list_data IN ('Genuine','OEM','Aftermarket','Used');

  -- Part categories (expected six)
  SELECT COALESCE(
           jsonb_agg(
             (SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x)
             ORDER BY ld.list_data
           ),
           '[]'::jsonb
         )
  INTO v_part_categories
  FROM qvm_new_apps.list_data ld
  WHERE ld.list_data IN ('Oil','Filter','Body','Mech/Elec','Accessories','Others');

  -- Price categories (from cost_categories)
  SELECT COALESCE(
           jsonb_agg(
             (SELECT x FROM (
                SELECT cc.cost_range_id AS id,
                       ((cc.cost_range->>0)::numeric || ' - ' || (cc.cost_range->>1)::numeric) AS name,
                       cc.cost_range
             ) x)
             ORDER BY (cc.cost_range->>0)::numeric
           ),
           '[]'::jsonb
         )
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
GRANT EXECUTE ON FUNCTION public.list_profit_filters() TO authenticated;;
