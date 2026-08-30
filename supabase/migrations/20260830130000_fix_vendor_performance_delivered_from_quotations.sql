-- Fix qvm_new_apps.get_vendor_performance_report's "delivered" metric.
--
-- It was previously joined through purchase_orders -> purchase_items -> confirmed_items, requiring
-- confirmed_items.item_status IN (23, 31). Verified live that this chain under-counts: for a vendor
-- with real delivered orders (e.g. vendor_id 686), quotation_items.item_status had already advanced
-- to 23 (Delivered) while the *linked* confirmed_items.item_status was still stuck at 21
-- (Processing) — the two drift independently and confirmed_items is not the current source of truth.
-- quotation_items.item_status is what the rest of the app treats as authoritative for an item's real
-- status (see get_internal_actions), so delivered is now judged directly off the vendor's own
-- quotation items via quotation_items.cost_id = quotation_vendor_items.cost_id — i.e. as a
-- quotation / vendor-quotation concept, not a purchase-order one. purchase_orders/purchase_items are
-- no longer consulted for this metric.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_performance_report(
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
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.received_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendors qv
        WHERE qv.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR qv.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi
            WHERE qi.quotation_id = qv.quotation_id AND qi.customer_id = p_branch_id
          ))
      ) AS received_count,
      (
        SELECT count(DISTINCT qvi.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv2 ON qv2.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qvi.vendor_id = v.vendor_id
          AND qvi.cost IS NOT NULL AND qvi.cost > 0
          AND (p_date_from IS NULL OR qv2.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv2.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = qv2.quotation_id AND qi2.customer_id = p_branch_id
          ))
      ) AS priced_count,
      (
        SELECT count(DISTINCT co.confirmed_order_id)
        FROM qvm_new_apps.confirmed_orders co
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
        JOIN qvm_new_apps.quotation_items qi3 ON qi3.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi3 ON qvi3.cost_id = qi3.cost_id
        WHERE qvi3.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR co.created_at >= p_date_from)
          AND (p_date_to IS NULL OR co.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi3.customer_id = p_branch_id)
      ) AS confirmed_count,
      (
        SELECT count(DISTINCT qi4.quotation_id)
        FROM qvm_new_apps.quotation_items qi4
        JOIN qvm_new_apps.quotation_vendor_items qvi4 ON qvi4.cost_id = qi4.cost_id
        JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = qi4.quotation_id
        WHERE qvi4.vendor_id = v.vendor_id
          AND qi4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR q4.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q4.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi4.customer_id = p_branch_id)
      ) AS delivered_count,
      (
        SELECT count(DISTINCT qvi5.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi5
        JOIN qvm_new_apps.quotation_vendors qv5 ON qv5.quotation_vendor_id = qvi5.quotation_vendor_id
        WHERE qvi5.vendor_id = v.vendor_id
          AND qvi5.vendor_item_status = 161
          AND (p_date_from IS NULL OR qv5.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv5.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi5
            WHERE qi5.quotation_id = qv5.quotation_id AND qi5.customer_id = p_branch_id
          ))
      ) AS unavailable_count
    FROM qvm_new_apps.vendors v
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_performance_report(integer, timestamptz, timestamptz) TO authenticated;
