-- New "Vendor Reports" tab: two per-vendor RPCs.
--
-- 1) get_vendor_sla_accuracy_report — per vendor, how the SLA they committed to at pricing time
--    (quotation_vendor_items.sla_hours) compares to the real time an order took to reach
--    "Out for Delivery" (item_status = 22), measured from purchase_orders.created_at (PO creation,
--    primary record — see 20260830240000's header for why this is trustworthy) to
--    qvm_new_apps.delivery_items.created_at (the "Out for Delivery" event's own dedicated table,
--    created atomically by the same action that flips item_status to 22 — the qvm_new_apps.deliveries/
--    delivery_items pair is the OOFD-side twin of delivery_notes, same reasoning: a primary record,
--    not a log, so it can't be silently missing). sla_accuracy_pct = SLA hours as a percentage of
--    actual hours (100% = delivered exactly on the promised time; >100% = faster than promised;
--    <100% = slower than promised). Reuses the item_po (confirmed_item -> ITS OWN purchase_items
--    row) dedup pattern from 20260830240000 to avoid the same one-order-multiple-POs fan-out bug.
--    live SLA coverage is sparse (2 of 326 quotation_vendor_items rows have sla_hours set) — this
--    report will show real numbers for whichever vendors have committed an SLA.
--
-- 2) get_vendor_response_time_report — per vendor, average time from being sent the RFQ
--    (quotation_vendors.created_at) to entering a price (quotation_vendor_items.updated_at, set
--    atomically with .cost by the vendor's pricing-save action — see 20260830170000's header for
--    why this, not item_status, is the reliable "priced" signal at the vendor-item level).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_sla_accuracy_report(
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
      qvi.sla_hours,
      extract(epoch FROM (di.created_at - ip.po_created_at)) / 3600.0 AS actual_hours
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
      round(avg(m.sla_hours)::numeric, 1) AS avg_sla_hours,
      round(avg(m.actual_hours)::numeric, 1) AS avg_actual_hours,
      round(avg(m.sla_hours / NULLIF(m.actual_hours, 0) * 100)::numeric, 1) AS sla_accuracy_pct
    FROM measured m
    JOIN qvm_new_apps.vendors v ON v.vendor_id = m.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_sla_accuracy_report(integer, timestamptz, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_response_time_report(
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
    SELECT DISTINCT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  measured AS (
    SELECT
      qv.vendor_id,
      extract(epoch FROM (qvi.updated_at - qv.created_at)) / 3600.0 AS response_hours
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    JOIN scoped_items si ON si.quotation_item_id = qvi.quotation_item_id
    WHERE qvi.cost IS NOT NULL AND qvi.updated_at > qv.created_at
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.quote_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      count(*) AS quote_count,
      round(avg(m.response_hours)::numeric, 1) AS avg_response_hours
    FROM measured m
    JOIN qvm_new_apps.vendors v ON v.vendor_id = m.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_response_time_report(integer, timestamptz, timestamptz) TO authenticated;
