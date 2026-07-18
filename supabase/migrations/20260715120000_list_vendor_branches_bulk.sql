-- Bulk variant of list_vendor_branches — the Send RFQ modal's brand/category filter needs each
-- listed vendor's branches (with brands/categories) up front to decide whether to hide a vendor
-- entirely (no branch matches the filter), rather than lazily per-vendor on selection. Returns a
-- jsonb object keyed by vendor_id so the frontend can merge it straight into its existing
-- per-vendor branches map.

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

  SELECT COALESCE(jsonb_object_agg(grouped.vendor_id, grouped.branches), '{}'::jsonb)
  INTO v_result
  FROM (
    SELECT vb.vendor_id,
           jsonb_agg(jsonb_build_object(
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
    WHERE vb.vendor_id = ANY(p_vendor_ids)
      AND (NOT p_active_only OR vb.is_active)
    GROUP BY vb.vendor_id
  ) grouped;

  RETURN v_result;
END;
$function$;
