-- Add location_lat/location_lng to client_branches (same naming as vendor_branches' existing
-- columns), so the client side of get_client_vendor_location_report can be resolved from real
-- coordinates instead of the free-text city column — more precise, and consistent with how the
-- vendor side is already resolved. Purely additive; existing rows get NULL until populated.
ALTER TABLE qvm_new_apps.client_branches
  ADD COLUMN IF NOT EXISTS location_lat double precision,
  ADD COLUMN IF NOT EXISTS location_lng double precision;

-- Rebuild get_client_vendor_location_report to require BOTH sides to have real coordinates,
-- returning client lat/lng alongside vendor lat/lng (frontend resolves both via the same
-- resolveCityKeyFromCoords nearest-anchor lookup, replacing the old cb.city + matchCity() text
-- path). Note: client_branches.location_lat/lng start out entirely empty — this report will show
-- zero rows until real coordinates are entered per branch; that's expected, not a bug.
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
    SELECT qi.quotation_item_id, qi.cost_id, qi.customer_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      cb.branch_name AS client_branch_name,
      cb.location_lat AS client_lat,
      cb.location_lng AS client_lng,
      vb.location_lat AS vendor_lat,
      vb.location_lng AS vendor_lng
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = si.customer_id
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = si.cost_id
    LEFT JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    LEFT JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    LEFT JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id AND po.vendor_id = qvi.vendor_id
    JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = COALESCE(po.vendor_branch_id, qv.vendor_branch_id)
    WHERE cb.location_lat IS NOT NULL AND cb.location_lng IS NOT NULL
      AND vb.location_lat IS NOT NULL AND vb.location_lng IS NOT NULL
  ) r;

  RETURN v_result;
END;
$function$;
