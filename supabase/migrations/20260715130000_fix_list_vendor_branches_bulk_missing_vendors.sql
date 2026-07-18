-- list_vendor_branches_bulk only emitted a key for vendor_ids that had at least one matching row
-- in vendor_branches (a plain GROUP BY over matched rows). A vendor with zero branches (or zero
-- *active* branches, since p_active_only defaults true) was simply absent from the result jsonb,
-- which the frontend can't tell apart from "not fetched yet" (both read as `undefined` in its
-- vendorBranchesMap) — so that vendor never gets cached and stays visible forever (fail open),
-- and gets re-requested on every filter change. Fix: drive the aggregation from the requested
-- vendor_ids via unnest + LEFT JOIN LATERAL, so every requested id gets an entry, defaulting to
-- an empty array when it has no (active) branches.

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches_bulk(p_vendor_ids integer[], p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_object_agg(vid.vendor_id, COALESCE(b.branches, '[]'::jsonb)), '{}'::jsonb)
  INTO v_result
  FROM unnest(p_vendor_ids) AS vid(vendor_id)
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
             'vendor_branch_id', vb.vendor_branch_id,
             'vendor_id', vb.vendor_id,
             'branch_name', vb.branch_name,
             'city', vb.city,
             'phone', vb.phone,
             'location_lat', vb.location_lat,
             'location_lng', vb.location_lng,
             'address', vb.address,
             'brands', vb.brands,
             'categories', vb.categories,
             'is_active', vb.is_active
           ) ORDER BY vb.city, vb.branch_name) AS branches
    FROM qvm_new_apps.vendor_branches vb
    WHERE vb.vendor_id = vid.vendor_id
      AND (NOT p_active_only OR vb.is_active)
  ) b ON true;

  RETURN v_result;
END;
$function$;
