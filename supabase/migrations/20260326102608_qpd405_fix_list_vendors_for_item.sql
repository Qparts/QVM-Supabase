-- Synced from QVM/test branch applied migration history (version 20260326102608, name: qpd405_fix_list_vendors_for_item)
CREATE OR REPLACE FUNCTION public.list_vendors_for_item(
  p_confirmed_item_id int
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  WITH base AS (
    SELECT ci.confirmed_item_id, qi.cost_id
    FROM qvm_new_apps.confirmed_items ci
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE ci.confirmed_item_id = p_confirmed_item_id
  )
  SELECT coalesce(jsonb_agg((SELECT x FROM (SELECT ld.list_data_id AS id, ld.list_data AS name) x) ORDER BY ld.list_data), '[]'::jsonb)
  FROM base b
  JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = b.cost_id
  JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qvi.vendor_id;
$$;

REVOKE ALL ON FUNCTION public.list_vendors_for_item(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_vendors_for_item(int) TO authenticated;;
