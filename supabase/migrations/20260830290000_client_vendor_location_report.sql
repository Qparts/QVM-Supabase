-- Vendor Performance Reports tab: raw per-confirmed-item rows of {client branch city, vendor
-- branch lat/lng}, for the "Local vs. Other City" report. All city-name/coordinate resolution
-- logic stays in the frontend (pages/management-overview/SaudiHeatMap.tsx's matchCity +
-- cityCoordinates.ts's resolveCityKeyFromCoords), matching this tab's established convention of
-- keeping geo-alias knowledge in one place rather than duplicating it in SQL.
--
-- The winning vendor's branch is resolved via COALESCE(purchase_orders.vendor_branch_id,
-- quotation_vendors.vendor_branch_id) — the PO's own branch when a PO exists (most authoritative,
-- since that's literally who was purchased from), falling back to the branch that priced the
-- quotation otherwise. Rows are only returned when the resolved vendor_branches row actually has
-- location_lat/location_lng populated — per the user's explicit instruction to derive location from
-- coordinates, not vendor_branches.city (which is free text and, verified live, inconsistently
-- populated: values like "Unknown", "Al Hair", "Al Ahsa Governorate" mixing English/Arabic and
-- district-level granularity). Coverage is sparse today — most vendor_branches rows have NULL
-- coordinates — so this report will show far fewer rows than a city-text-based version would, by
-- design: excluding an unresolvable row is preferable to guessing.
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
      cb.city AS client_city,
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
    WHERE vb.location_lat IS NOT NULL AND vb.location_lng IS NOT NULL
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_client_vendor_location_report(integer, timestamptz, timestamptz) TO authenticated;
