-- Synced from QVM/test branch applied migration history (version 20260706160941, name: vendor_branch_phone_and_user_edit_delete)
-- Vendor multi-branch (Phase 3): branch phone number + vendor user edit/delete support.

-- 1. vendor_branches: mobile phone per branch ------------------------------------------------

ALTER TABLE qvm_new_apps.vendor_branches
  ADD COLUMN phone text;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches(p_vendor_id integer, p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

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
           'is_active', vb.is_active
         ) ORDER BY vb.city, vb.branch_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = p_vendor_id
    AND (NOT p_active_only OR vb.is_active);

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendor_branch(p_vendor_id integer, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_new_id bigint;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF NULLIF(trim(p_branch->>'branch_name'), '') IS NULL OR NULLIF(trim(p_branch->>'city'), '') IS NULL THEN
    RAISE EXCEPTION 'branch_name and city are required';
  END IF;

  INSERT INTO qvm_new_apps.vendor_branches (
    vendor_id, branch_name, city, phone, location_lat, location_lng, address, brands, categories, is_active
  ) VALUES (
    p_vendor_id,
    p_branch->>'branch_name',
    p_branch->>'city',
    NULLIF(trim(p_branch->>'phone'), ''),
    NULLIF(p_branch->>'location_lat', '')::double precision,
    NULLIF(p_branch->>'location_lng', '')::double precision,
    p_branch->>'address',
    COALESCE(p_branch->'brands', '[]'::jsonb),
    COALESCE(p_branch->'categories', '[]'::jsonb),
    COALESCE((p_branch->>'is_active')::boolean, true)
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.update_vendor_branch(p_vendor_branch_id bigint, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_vendor_id integer;
BEGIN
  SELECT vendor_id INTO v_vendor_id FROM qvm_new_apps.vendor_branches WHERE vendor_branch_id = p_vendor_branch_id;
  IF v_vendor_id IS NULL THEN
    RAISE EXCEPTION 'Branch not found';
  END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE qvm_new_apps.vendor_branches SET
    branch_name = COALESCE(p_branch->>'branch_name', branch_name),
    city = COALESCE(p_branch->>'city', city),
    phone = CASE WHEN p_branch ? 'phone' THEN NULLIF(trim(p_branch->>'phone'), '') ELSE phone END,
    location_lat = CASE WHEN p_branch ? 'location_lat' THEN NULLIF(p_branch->>'location_lat', '')::double precision ELSE location_lat END,
    location_lng = CASE WHEN p_branch ? 'location_lng' THEN NULLIF(p_branch->>'location_lng', '')::double precision ELSE location_lng END,
    address = COALESCE(p_branch->>'address', address),
    brands = COALESCE(p_branch->'brands', brands),
    categories = COALESCE(p_branch->'categories', categories),
    is_active = COALESCE((p_branch->>'is_active')::boolean, is_active),
    updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;
;
