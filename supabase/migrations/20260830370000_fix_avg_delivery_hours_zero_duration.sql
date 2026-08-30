-- Fix get_purchases_overview_stats: avg_delivery_hours was returning NULL because both real
-- delivery_items/delivery_notes pairs in this database have IDENTICAL timestamps (Out for Delivery
-- and Delivered signed in the same instant), and the previous strict "dn.created_at > di.created_at"
-- filter (guarding against reversed/bad timestamps) excluded zero-duration observations along with
-- genuinely invalid ones. A same-instant signing is a real, valid measurement (0 hours), not an
-- error — relaxed to ">=" so it reports 0.0 instead of hiding real data as NULL.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchases_overview_stats(
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
  v_purchase_invoice_count integer;
  v_purchase_order_count integer;
  v_avg_delivery_hours numeric;
  v_avg_purchasing_hours numeric;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only');
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  WITH scoped_items AS (
    SELECT qi.quotation_item_id, qi.cost_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  scoped_pos AS (
    SELECT DISTINCT po.purchase_order_id
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
  )
  SELECT count(*) INTO v_purchase_order_count FROM scoped_pos;

  SELECT count(DISTINCT pia.attachment_id) INTO v_purchase_invoice_count
  FROM qvm_new_apps.purchase_invoice_attachments pia
  JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = pia.purchase_order_id
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
  WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
    AND (p_date_to IS NULL OR q.created_at <= p_date_to)
    AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
    AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope));

  WITH scoped_items AS (
    SELECT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  )
  SELECT round(avg(extract(epoch FROM (dn.created_at - di.created_at)) / 3600.0)::numeric, 1)
    INTO v_avg_delivery_hours
  FROM qvm_new_apps.delivery_items di
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
  JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
  JOIN qvm_new_apps.delivery_notes dn ON dn.confirmed_item_id = ci.confirmed_item_id
  WHERE dn.created_at >= di.created_at;

  WITH scoped_items AS (
    SELECT qi.quotation_item_id, qi.cost_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  priced AS (
    SELECT quotation_item_id, min(created_at) AS entered_at
    FROM qvm_new_apps.pricing_logs
    GROUP BY quotation_item_id
  )
  SELECT round(avg(extract(epoch FROM (p.entered_at - qv.created_at)) / 3600.0)::numeric, 1)
    INTO v_avg_purchasing_hours
  FROM priced p
  JOIN scoped_items si ON si.quotation_item_id = p.quotation_item_id
  JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = si.cost_id
  JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
  WHERE p.entered_at > qv.created_at;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'purchase_invoice_count', v_purchase_invoice_count,
      'purchase_order_count', v_purchase_order_count,
      'avg_delivery_hours', v_avg_delivery_hours,
      'avg_purchasing_hours', v_avg_purchasing_hours
    )
  );
END;
$function$;
