-- Management Overview → "Management Reports" tab: second report block — a per-vendor table with
-- Received / Priced / Confirmed-to-order / Delivered-PO / Unavailable counts.
--
-- Status codes used (verified live against qvm_new_apps.list_data, list_name = 'vendor_status'):
--   161 = "غير متوفر" (Unavailable)                — on quotation_vendor_items.vendor_item_status
--   164 = "تم التسليم" (Delivered)                  — on purchase_orders.vendor_status
-- "Priced" is NOT taken from vendor_item_status (158 gets superseded by 159/207 once an order is
-- confirmed) — mirrors get_internal_actions' own precedent of using cost IS NOT NULL AND cost > 0
-- as the durable "did this vendor quote a price" signal across the item's whole lifecycle.
-- "Confirmed to become an order" has no direct vendor_id on confirmed_items/confirmed_orders; the
-- winning vendor is resolved via quotation_items.cost_id = quotation_vendor_items.cost_id, the same
-- join chain used throughout the purchase-invoices dashboard RPCs.
-- "Delivered PO" is judged off confirmed_items.item_status (23 Delivered / 31 Settled) via
-- purchase_items, not purchase_orders.vendor_status = 164 — that status code is defined but no
-- code path in this codebase was found to ever set it, whereas the delivery-note flow actively
-- maintains item_status 23/31. A PO counts as delivered as soon as ANY of its linked items reaches
-- that status (not all) — flag to revisit if "fully delivered" is the intended semantics instead.
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
        SELECT count(DISTINCT po.purchase_order_id)
        FROM qvm_new_apps.purchase_orders po
        JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
        JOIN qvm_new_apps.confirmed_items ci4 ON ci4.confirmed_item_id = pi.confirmed_item_id
        JOIN qvm_new_apps.confirmed_orders co2 ON co2.confirmed_order_id = po.confirmed_order_id
        WHERE po.vendor_id = v.vendor_id
          AND ci4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR po.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi4
            WHERE qi4.quotation_id = co2.quotation_id AND qi4.customer_id = p_branch_id
          ))
      ) AS delivered_po_count,
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
