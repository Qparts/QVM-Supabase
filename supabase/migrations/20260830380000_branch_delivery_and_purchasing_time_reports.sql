-- Purchases Performance Reports tab: per-client-branch breakdown of the two duration metrics
-- already computed system-wide in get_purchases_overview_stats.
--
--   get_branch_delivery_time_report — avg hours from "Out for Delivery"
--     (qvm_new_apps.delivery_items.created_at) to "Delivered" (qvm_new_apps.delivery_notes.created_at),
--     grouped by the client branch that created the underlying quotation (quotation_items.customer_id).
--     Same ">=" relaxation as the system-wide stat (20260830370000) — a same-instant signing is a
--     real zero-duration observation, not something to hide as NULL.
--   get_branch_purchasing_time_report — avg hours from the RFQ being sent to a vendor
--     (quotation_vendors.created_at) to the item's selling price being set
--     (pricing_logs.created_at, earliest per item, winning vendor), grouped the same way.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_branch_delivery_time_report(
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
  measured AS (
    SELECT
      si.customer_id,
      extract(epoch FROM (dn.created_at - di.created_at)) / 3600.0 AS hours
    FROM qvm_new_apps.delivery_items di
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.delivery_notes dn ON dn.confirmed_item_id = ci.confirmed_item_id
    WHERE dn.created_at >= di.created_at
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.order_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.branch_name,
      count(*) AS order_count,
      round(avg(m.hours)::numeric, 1) AS avg_hours
    FROM measured m
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = m.customer_id
    GROUP BY cb.customer_id, cb.branch_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_branch_delivery_time_report(integer, timestamptz, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_branch_purchasing_time_report(
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
    SELECT qi.quotation_item_id, qi.cost_id, qi.customer_id
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
  ),
  measured AS (
    SELECT
      si.customer_id,
      extract(epoch FROM (p.entered_at - qv.created_at)) / 3600.0 AS hours
    FROM priced p
    JOIN scoped_items si ON si.quotation_item_id = p.quotation_item_id
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = si.cost_id
    JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    WHERE p.entered_at > qv.created_at
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.order_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.branch_name,
      count(*) AS order_count,
      round(avg(m.hours)::numeric, 1) AS avg_hours
    FROM measured m
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = m.customer_id
    GROUP BY cb.customer_id, cb.branch_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_branch_purchasing_time_report(integer, timestamptz, timestamptz) TO authenticated;
