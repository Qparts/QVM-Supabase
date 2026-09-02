-- Compares a given vendor against every other vendor that quoted on the same quotations
-- (i.e. shares quotation_vendors rows on the quotations the target vendor participated in).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_comparison_report(p_vendor_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  WITH target_quotations AS (
    SELECT DISTINCT qv.quotation_id
    FROM qvm_new_apps.quotation_vendors qv
    WHERE qv.vendor_id = p_vendor_id
  ),
  quotation_brand AS (
    SELECT DISTINCT ON (qi.quotation_id)
      qi.quotation_id, ld.list_data AS brand
    FROM qvm_new_apps.quotation_items qi
    JOIN target_quotations tq ON tq.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
    ORDER BY qi.quotation_id, qi.quotation_item_id
  ),
  quotation_branch AS (
    SELECT DISTINCT ON (qi.quotation_id)
      qi.quotation_id, ld.list_data AS branch
    FROM qvm_new_apps.quotation_items qi
    JOIN target_quotations tq ON tq.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.customer_id
    ORDER BY qi.quotation_id, qi.quotation_item_id
  ),
  vendor_agg AS (
    SELECT
      qvi.quotation_vendor_id,
      count(*) AS vendor_items_count,
      max(qvi.updated_at) AS pricing_date,
      sum(qvi.cost) AS vendor_quotation_total
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    WHERE qv.quotation_id IN (SELECT quotation_id FROM target_quotations)
    GROUP BY qvi.quotation_vendor_id
  ),
  purchased_agg AS (
    SELECT
      qvi.quotation_vendor_id,
      count(*) AS purchased_items_count,
      sum(qvi.cost) AS purchased_items_total
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    JOIN qvm_new_apps.purchase_items pi ON pi.cost_id = qvi.cost_id
    WHERE qv.quotation_id IN (SELECT quotation_id FROM target_quotations)
      AND qvi.cost_id IS NOT NULL
    GROUP BY qvi.quotation_vendor_id
  ),
  rows_cte AS (
    SELECT
      q.order_number,
      q.created_at                                AS quotation_date,
      qb.brand,
      qbr.branch,
      COALESCE(va.vendor_items_count, 0)          AS vendor_items_count,
      v.vendor_name,
      qv.created_at                               AS vendor_quotation_date,
      va.pricing_date,
      COALESCE(va.vendor_quotation_total, 0)      AS vendor_quotation_total,
      COALESCE(pa.purchased_items_count, 0)       AS purchased_items_count,
      COALESCE(pa.purchased_items_total, 0)       AS purchased_items_total,
      (v.vendor_id = p_vendor_id)                 AS is_target_vendor
    FROM qvm_new_apps.quotation_vendors qv
    JOIN target_quotations tq ON tq.quotation_id = qv.quotation_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qv.quotation_id
    JOIN qvm_new_apps.vendors v ON v.vendor_id = qv.vendor_id
    LEFT JOIN quotation_brand qb ON qb.quotation_id = qv.quotation_id
    LEFT JOIN quotation_branch qbr ON qbr.quotation_id = qv.quotation_id
    LEFT JOIN vendor_agg va ON va.quotation_vendor_id = qv.quotation_vendor_id
    LEFT JOIN purchased_agg pa ON pa.quotation_vendor_id = qv.quotation_vendor_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.quotation_date DESC, r.is_target_vendor DESC, r.vendor_name), '[]'::jsonb)
  ) INTO v_result
  FROM rows_cte r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_comparison_report(integer) TO authenticated;
