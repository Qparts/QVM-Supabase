-- Lets an admin-vendor mark one of their branches as "preferred" — internal staff's Send RFQ
-- modals then default the branch picker to it for that vendor, instead of forcing a manual pick
-- every time.

ALTER TABLE qvm_new_apps.vendors
  ADD COLUMN preferred_branch_id bigint REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_preferred_branch(p_vendor_id integer, p_vendor_branch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_vendor_admin_for(p_vendor_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Not authorized');
  END IF;

  IF p_vendor_branch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.vendor_branches
    WHERE vendor_branch_id = p_vendor_branch_id AND vendor_id = p_vendor_id
  ) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Branch does not belong to this vendor');
  END IF;

  UPDATE qvm_new_apps.vendors
  SET preferred_branch_id = p_vendor_branch_id
  WHERE vendor_id = p_vendor_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_vendor_preferred_branch(p_vendor_id integer, p_vendor_branch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN qvm_new_apps.set_vendor_preferred_branch(p_vendor_id, p_vendor_branch_id);
END;
$function$;

-- Surface the preference alongside the branch list so both the vendor dashboard (to show/manage
-- it) and the internal Send RFQ modals (to auto-select it) get it in the same round trip.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches(p_vendor_id integer, p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_preferred_branch_id bigint;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT v.preferred_branch_id INTO v_preferred_branch_id
  FROM qvm_new_apps.vendors v
  WHERE v.vendor_id = p_vendor_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
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
           'is_active', vb.is_active,
           'is_preferred', (vb.vendor_branch_id = v_preferred_branch_id)
         ) ORDER BY vb.city, vb.branch_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = p_vendor_id
    AND (NOT p_active_only OR vb.is_active);

  RETURN v_result;
END;
$function$;
