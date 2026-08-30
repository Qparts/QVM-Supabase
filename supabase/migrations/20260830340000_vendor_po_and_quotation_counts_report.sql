-- Vendor Performance Reports tab: simple per-vendor table of Purchase Order count vs. Vendor
-- Quotation count. "Vendor quotation" = a quotation_vendors row (the vendor was sent this RFQ);
-- "Purchase order" = a purchase_orders row (this vendor was actually bought from). Both counts are
-- scoped to items/quotations passing the same branch/date filters as the rest of this tab.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_po_and_quotation_counts_report(
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

  WITH scoped_items AS (
    SELECT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  scoped_quotation_vendors AS (
    SELECT DISTINCT qv.quotation_vendor_id, qv.vendor_id
    FROM qvm_new_apps.quotation_vendors qv
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = qv.quotation_id
    JOIN scoped_items si ON si.quotation_item_id = qi.quotation_item_id
  ),
  scoped_purchase_orders AS (
    SELECT DISTINCT po.purchase_order_id, po.vendor_id
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
  ),
  vendor_ids AS (
    SELECT vendor_id FROM scoped_quotation_vendors
    UNION
    SELECT vendor_id FROM scoped_purchase_orders
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.quotation_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      COALESCE((SELECT count(*) FROM scoped_purchase_orders spo WHERE spo.vendor_id = v.vendor_id), 0) AS po_count,
      COALESCE((SELECT count(*) FROM scoped_quotation_vendors sqv WHERE sqv.vendor_id = v.vendor_id), 0) AS quotation_count
    FROM vendor_ids vi
    JOIN qvm_new_apps.vendors v ON v.vendor_id = vi.vendor_id
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_po_and_quotation_counts_report(integer, timestamptz, timestamptz) TO authenticated;
