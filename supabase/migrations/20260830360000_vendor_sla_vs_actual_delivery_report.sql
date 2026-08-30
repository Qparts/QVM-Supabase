-- Vendor Performance Reports tab: per-vendor SLA (days) vs. actual delivery duration (days),
-- matching the "مدة التوريد مقابل اتفاقية الخدمة" reference design.
--
-- Same span as get_vendor_sla_accuracy_report's donut: "actual" is PO created -> Out for Delivery
-- (purchase_orders.created_at -> qvm_new_apps.delivery_items.created_at, the OOFD-signing record),
-- via each item's own purchase_items row, using the same fan-out-safe join pattern established in
-- 20260830240000. SLA is quotation_vendor_items.sla_hours for the winning vendor, converted to
-- days. Only items where BOTH an SLA and a real OOFD event exist are counted, so the two averages
-- are over the same matched population, not separately-sampled sets.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_sla_vs_actual_delivery_report(
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
    SELECT qi.quotation_item_id, qi.cost_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  item_po AS (
    SELECT ci.confirmed_item_id, ci.quotation_item_id, min(po.created_at) AS po_created_at
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.purchase_items pi ON pi.confirmed_item_id = ci.confirmed_item_id
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    GROUP BY ci.confirmed_item_id, ci.quotation_item_id
  ),
  measured AS (
    SELECT
      qvi.vendor_id,
      qvi.sla_hours / 24.0 AS sla_days,
      extract(epoch FROM (di.created_at - ip.po_created_at)) / 86400.0 AS actual_days
    FROM item_po ip
    JOIN scoped_items si ON si.quotation_item_id = ip.quotation_item_id
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = si.cost_id
    JOIN qvm_new_apps.delivery_items di ON di.confirmed_item_id = ip.confirmed_item_id
    WHERE qvi.sla_hours IS NOT NULL
      AND di.created_at > ip.po_created_at
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.order_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      count(*) AS order_count,
      round(avg(m.sla_days)::numeric, 1) AS avg_sla_days,
      round(avg(m.actual_days)::numeric, 1) AS avg_actual_days,
      round((avg(m.actual_days) - avg(m.sla_days))::numeric, 1) AS diff_days
    FROM measured m
    JOIN qvm_new_apps.vendors v ON v.vendor_id = m.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_sla_vs_actual_delivery_report(integer, timestamptz, timestamptz) TO authenticated;
