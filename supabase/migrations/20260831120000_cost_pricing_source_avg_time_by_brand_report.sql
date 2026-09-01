-- Extract PN Reports tab: pricing-source breakdown by brand, backed by qvm_new_apps.cost_logs.
-- For each cost_logs row (a vendor-cost pricing event):
--   - brand: cost_logs.cost_id -> quotation_vendor_items.quotation_item_id -> quotation_items.main_brand
--   - pricing source: cost_logs.created_by -> user_data.user_id; user_data.user_vendor IS NULL means
--     an internal (Qparts) user priced it, otherwise a vendor user priced it themselves
--   - duration: quotation_vendor_items.updated_at - created_at for that cost_id (cost_logs itself has
--     no updated_at column) — how long that vendor-item row took to get its cost set
-- Grouped by (brand, pricing_source), averaged, scoped/filterable by branch and date range like the
-- rest of this tab's reports (filtering on cost_logs.created_at).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_cost_pricing_source_avg_time_by_brand_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.avg_hours DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      qi.main_brand AS brand_id,
      ld.list_data AS brand_name,
      CASE WHEN ud.user_vendor IS NULL THEN 'internal' ELSE 'vendor' END AS pricing_source,
      count(*) AS event_count,
      round((avg(extract(epoch FROM (qvi.updated_at - qvi.created_at))) / 3600.0)::numeric, 1) AS avg_hours
    FROM qvm_new_apps.cost_logs cl
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = cl.cost_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = cl.created_by
    WHERE qi.main_brand IS NOT NULL
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
      AND (p_date_from IS NULL OR cl.created_at >= p_date_from)
      AND (p_date_to IS NULL OR cl.created_at <= p_date_to)
    GROUP BY qi.main_brand, ld.list_data, (CASE WHEN ud.user_vendor IS NULL THEN 'internal' ELSE 'vendor' END)
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_cost_pricing_source_avg_time_by_brand_report(integer, timestamptz, timestamptz) TO authenticated;
