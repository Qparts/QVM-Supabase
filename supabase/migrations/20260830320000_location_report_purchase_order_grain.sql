-- Fix get_client_vendor_location_report: count PURCHASE ORDERS per vendor (same city vs. other
-- city), not quotations/confirmed items. A purchase order is the concrete "we actually bought from
-- this vendor" unit — previously this counted distinct quotation_id per vendor via confirmed_items,
-- which could differ from actual PO counts (e.g. a PO not yet created, or the fan-out risk of
-- multiple POs per confirmed item). Uses purchase_orders.vendor_branch_id directly (the PO's own
-- recorded branch — no fallback to quotation_vendors needed here, since a PO by definition already
-- has this set), joined back to its originating client branch via purchase_items ->
-- confirmed_items -> quotation_items.customer_id.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_client_vendor_location_report(
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
    SELECT qi.quotation_item_id, qi.customer_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  scoped_pos AS (
    SELECT DISTINCT po.purchase_order_id, po.vendor_id, po.vendor_branch_id, si.customer_id
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    WHERE po.vendor_branch_id IS NOT NULL
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      spo.purchase_order_id,
      spo.vendor_id,
      v.vendor_name,
      cb.location_lat AS client_lat,
      cb.location_lng AS client_lng,
      vb.location_lat AS vendor_lat,
      vb.location_lng AS vendor_lng
    FROM scoped_pos spo
    JOIN qvm_new_apps.vendors v ON v.vendor_id = spo.vendor_id
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = spo.customer_id
    JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = spo.vendor_branch_id
    WHERE cb.location_lat IS NOT NULL AND cb.location_lng IS NOT NULL
      AND vb.location_lat IS NOT NULL AND vb.location_lng IS NOT NULL
  ) r;

  RETURN v_result;
END;
$function$;
