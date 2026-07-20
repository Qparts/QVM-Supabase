-- Supports the new Vendors admin UI: branches are now managed directly (create/edit/remove)
-- instead of vendor-level "Market"/"Banking" sections, with multi-bank support per branch via
-- the new vendor_branches.banks jsonb array (see 20260719230000).
--
-- create_vendor and save_vendor drop their migrated-field handling entirely: the new UI never
-- sends region/brands/payment_method/items_type/operating_hours/notify_*/bank data through
-- either of them anymore — that all goes through create_vendor_branch/update_vendor_branch
-- directly. Both become plain vendor-row functions again.

-- ============================================================================
-- create_vendor: vendor-row-only insert. Branches are created separately by the frontend via
-- create_vendor_branch, once per branch card, right after this returns.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_vendor(p_user_id uuid, p_vendor jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  new_id integer;
  v_vendor_name text;
  v_vendor_type text;
  v_vendor_type_id integer;
  v_receives_quotations boolean;
  v_cr text;
  v_tax text;
  v_zoho_name text;
  v_email text;
  v_phone_numbers jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_vendor_name := NULLIF(p_vendor->>'vendor_name', '');
  v_vendor_type := NULLIF(p_vendor->>'vendor_type', '');
  IF v_vendor_name IS NULL OR v_vendor_type IS NULL THEN
    RAISE EXCEPTION 'Missing required fields: vendor_name, vendor_type';
  END IF;

  v_vendor_type_id := NULLIF(p_vendor->>'vendor_type_id', '')::integer;
  v_receives_quotations := COALESCE((p_vendor->>'receives_quotations')::boolean, true);
  v_cr := NULLIF(p_vendor->>'commercial_registeration_number','');
  v_tax := NULLIF(p_vendor->>'tax_number','');
  v_zoho_name := NULLIF(p_vendor->>'zoho_name','');
  v_email := NULLIF(p_vendor->>'email','');
  v_phone_numbers := CASE WHEN p_vendor ? 'phone_numbers' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'phone_numbers') x WHERE trim(x) <> '')) ELSE NULL END;

  INSERT INTO qvm_new_apps.vendors (
    vendor_name, vendor_type, vendor_type_id, receives_quotations,
    tax_number, commercial_registeration_number,
    zoho_name, email, phone_numbers, created_at, updated_at
  ) VALUES (
    v_vendor_name, v_vendor_type, v_vendor_type_id, v_receives_quotations,
    v_tax, v_cr,
    v_zoho_name, v_email, v_phone_numbers, now(), now()
  ) RETURNING vendor_id INTO new_id;

  RETURN jsonb_build_object('status','success','vendor_id', new_id);
END;
$function$;

-- ============================================================================
-- save_vendor: vendor-row-only update. Branch fields (region/brands/payment/items/hours/
-- notify/banks) are edited directly via update_vendor_branch on each branch card now.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.save_vendor(p_user_id uuid, p_vendor_id integer, p_vendor jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_existing qvm_new_apps.vendors%ROWTYPE;
  v_changed text[] := ARRAY[]::text[];
  new_vendor_name text;
  new_vendor_type text;
  new_vendor_type_id integer;
  new_receives_quotations boolean;
  new_cr text;
  new_tax text;
  new_zoho_name text;
  new_email text;
  new_phone_numbers jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_existing
  FROM qvm_new_apps.vendors v
  WHERE v.vendor_id = p_vendor_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Vendor not found';
  END IF;

  new_vendor_name := COALESCE(NULLIF(p_vendor->>'vendor_name', ''), v_existing.vendor_name);
  new_vendor_type := COALESCE(NULLIF(p_vendor->>'vendor_type', ''), v_existing.vendor_type);
  new_vendor_type_id := COALESCE(NULLIF(p_vendor->>'vendor_type_id', '')::integer, v_existing.vendor_type_id);
  new_receives_quotations := COALESCE((p_vendor->>'receives_quotations')::boolean, v_existing.receives_quotations);
  new_cr := COALESCE(NULLIF(p_vendor->>'commercial_registeration_number',''), v_existing.commercial_registeration_number);
  new_tax := COALESCE(NULLIF(p_vendor->>'tax_number',''), v_existing.tax_number);
  new_zoho_name := COALESCE(NULLIF(p_vendor->>'zoho_name',''), v_existing.zoho_name);
  new_email := COALESCE(NULLIF(p_vendor->>'email',''), v_existing.email);
  new_phone_numbers := COALESCE(
    CASE WHEN p_vendor ? 'phone_numbers' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'phone_numbers') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_existing.phone_numbers
  );

  IF new_vendor_name IS DISTINCT FROM v_existing.vendor_name THEN v_changed := array_append(v_changed, 'vendor_name'); END IF;
  IF new_vendor_type IS DISTINCT FROM v_existing.vendor_type THEN v_changed := array_append(v_changed, 'vendor_type'); END IF;
  IF new_vendor_type_id IS DISTINCT FROM v_existing.vendor_type_id THEN v_changed := array_append(v_changed, 'vendor_type_id'); END IF;
  IF new_receives_quotations IS DISTINCT FROM v_existing.receives_quotations THEN v_changed := array_append(v_changed, 'receives_quotations'); END IF;
  IF new_cr IS DISTINCT FROM v_existing.commercial_registeration_number THEN v_changed := array_append(v_changed, 'commercial_registeration_number'); END IF;
  IF new_tax IS DISTINCT FROM v_existing.tax_number THEN v_changed := array_append(v_changed, 'tax_number'); END IF;
  IF new_zoho_name IS DISTINCT FROM v_existing.zoho_name THEN v_changed := array_append(v_changed, 'zoho_name'); END IF;
  IF new_email IS DISTINCT FROM v_existing.email THEN v_changed := array_append(v_changed, 'email'); END IF;
  IF new_phone_numbers IS DISTINCT FROM v_existing.phone_numbers THEN v_changed := array_append(v_changed, 'phone_numbers'); END IF;

  UPDATE qvm_new_apps.vendors
  SET vendor_name = new_vendor_name,
      vendor_type = new_vendor_type,
      vendor_type_id = new_vendor_type_id,
      receives_quotations = new_receives_quotations,
      tax_number = new_tax,
      commercial_registeration_number = new_cr,
      zoho_name = new_zoho_name,
      email = new_email,
      phone_numbers = new_phone_numbers,
      updated_at = now()
  WHERE vendor_id = p_vendor_id;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Vendor updated successfully',
    'vendor_id', p_vendor_id,
    'changed', v_changed
  );
END;
$function$;

-- ============================================================================
-- get_vendors_dashboard: bank fields now a single `banks` array from the preferred branch.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_vendors_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_vendor_types text[] DEFAULT NULL::text[], p_payment_methods text[] DEFAULT NULL::text[], p_brands text[] DEFAULT NULL::text[], p_regions text[] DEFAULT NULL::text[], p_limit integer DEFAULT 10, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_total int := 0;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  WITH base AS (
    SELECT v.*, pb.vendor_branch_id AS pb_vendor_branch_id,
           pb.region AS pb_region, pb.operating_hours AS pb_operating_hours, pb.brands AS pb_brands,
           pb.items_type AS pb_items_type, pb.payment_method AS pb_payment_method,
           pb.banks AS pb_banks, pb.location AS pb_location,
           pb.discount_percent AS pb_discount_percent,
           pb.notify_by_email AS pb_notify_by_email, pb.notify_by_whatsapp AS pb_notify_by_whatsapp
    FROM qvm_new_apps.vendors v
    LEFT JOIN qvm_new_apps.vendor_branches pb ON pb.vendor_branch_id = v.preferred_branch_id
    WHERE (
      p_search IS NULL OR p_search = '' OR (
        v.vendor_name ILIKE '%'||p_search||'%'
        OR COALESCE(v.zoho_name,'') ILIKE '%'||p_search||'%'
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.brands)='array' THEN pb.brands ELSE '[]'::jsonb END) b(val)
          WHERE val ILIKE '%'||p_search||'%'
        )
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.region)='array' THEN pb.region ELSE '[]'::jsonb END) r(val)
          WHERE val ILIKE '%'||p_search||'%'
        )
      )
    )
    AND (
      p_vendor_types IS NULL OR EXISTS (
        SELECT 1 FROM unnest(p_vendor_types) t WHERE lower(btrim(t)) = lower(btrim(COALESCE(v.vendor_type,'')))
      )
    )
    AND (
      p_payment_methods IS NULL OR EXISTS (
        SELECT 1
        FROM unnest(p_payment_methods) pm
        WHERE lower(btrim(pm)) = ANY(
          SELECT lower(btrim(x)) FROM regexp_split_to_table(COALESCE(pb.payment_method,''), '\s*,\s*') x
        )
      )
    )
    AND (
      p_brands IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.brands)='array' THEN pb.brands ELSE '[]'::jsonb END) b(val)
        WHERE lower(btrim(val)) = ANY (SELECT lower(btrim(x)) FROM unnest(p_brands) x)
      )
    )
    AND (
      p_regions IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.region)='array' THEN pb.region ELSE '[]'::jsonb END) r(val)
        WHERE lower(btrim(val)) = ANY (SELECT lower(btrim(x)) FROM unnest(p_regions) x)
      )
    )
  ),
  cnt AS (
    SELECT COUNT(*) AS c FROM base
  ),
  paged AS (
    SELECT
      v.vendor_id,
      v.vendor_name,
      v.zoho_name,
      v.vendor_type,
      v.vendor_type_id,
      v.receives_quotations,
      v.preferred_branch_id,
      v.pb_region AS region,
      v.pb_operating_hours AS operating_hours,
      v.pb_brands AS brands,
      v.pb_items_type AS items_type,
      v.pb_payment_method AS payment_method,
      v.tax_number,
      v.commercial_registeration_number,
      v.pb_banks AS banks,
      v.pb_location AS location,
      v.pb_discount_percent AS discount_percent,
      v.email,
      v.phone_numbers,
      v.pb_notify_by_email AS notify_by_email,
      v.pb_notify_by_whatsapp AS notify_by_whatsapp,
      v.created_at
    FROM base v
    ORDER BY v.created_at DESC NULLS LAST, v.vendor_id DESC
    LIMIT GREATEST(p_limit, 1) OFFSET GREATEST(p_offset, 0)
  )
  SELECT c.c,
         (SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC NULLS LAST, p.vendor_id DESC), '[]'::jsonb) FROM paged p)
  INTO v_total, v_rows
  FROM cnt c;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$function$;

-- ============================================================================
-- create_vendor_branch: single `banks` jsonb array param instead of individual bank_* fields.
-- ============================================================================
CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendor_branch(p_vendor_id integer, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
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
    vendor_id, branch_name, city, phone, location_lat, location_lng, address, brands, categories, is_active,
    region, operating_hours, items_type, payment_method, banks,
    location, discount_percent, notify_by_email, notify_by_whatsapp
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
    COALESCE((p_branch->>'is_active')::boolean, true),
    CASE WHEN p_branch ? 'region' THEN p_branch->'region' ELSE NULL END,
    CASE WHEN p_branch ? 'operating_hours' THEN p_branch->'operating_hours' ELSE NULL END,
    CASE WHEN p_branch ? 'items_type' THEN p_branch->'items_type' ELSE NULL END,
    NULLIF(p_branch->>'payment_method', ''),
    COALESCE(p_branch->'banks', '[]'::jsonb),
    NULLIF(p_branch->>'location', ''),
    NULLIF(p_branch->>'discount_percent', '')::double precision,
    COALESCE((p_branch->>'notify_by_email')::boolean, true),
    COALESCE((p_branch->>'notify_by_whatsapp')::boolean, false)
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
END;
$function$;

-- ============================================================================
-- update_vendor_branch: single `banks` jsonb array param instead of individual bank_* fields.
-- ============================================================================
CREATE OR REPLACE FUNCTION qvm_new_apps.update_vendor_branch(p_vendor_branch_id bigint, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
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
    region = CASE WHEN p_branch ? 'region' THEN p_branch->'region' ELSE region END,
    operating_hours = CASE WHEN p_branch ? 'operating_hours' THEN p_branch->'operating_hours' ELSE operating_hours END,
    items_type = CASE WHEN p_branch ? 'items_type' THEN p_branch->'items_type' ELSE items_type END,
    payment_method = CASE WHEN p_branch ? 'payment_method' THEN NULLIF(p_branch->>'payment_method', '') ELSE payment_method END,
    banks = CASE WHEN p_branch ? 'banks' THEN p_branch->'banks' ELSE banks END,
    location = CASE WHEN p_branch ? 'location' THEN NULLIF(p_branch->>'location', '') ELSE location END,
    discount_percent = CASE WHEN p_branch ? 'discount_percent' THEN NULLIF(p_branch->>'discount_percent', '')::double precision ELSE discount_percent END,
    notify_by_email = COALESCE((p_branch->>'notify_by_email')::boolean, notify_by_email),
    notify_by_whatsapp = COALESCE((p_branch->>'notify_by_whatsapp')::boolean, notify_by_whatsapp),
    updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

-- ============================================================================
-- list_vendor_branches / list_vendor_branches_bulk: return the full branch shape so the admin
-- form can load and edit region/payment/items/hours/banks/notify per branch.
-- ============================================================================
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
           'is_preferred', (vb.vendor_branch_id = v_preferred_branch_id),
           'region', vb.region,
           'operating_hours', vb.operating_hours,
           'items_type', vb.items_type,
           'payment_method', vb.payment_method,
           'banks', vb.banks,
           'notify_by_email', vb.notify_by_email,
           'notify_by_whatsapp', vb.notify_by_whatsapp
         ) ORDER BY vb.city, vb.branch_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = p_vendor_id
    AND (NOT p_active_only OR vb.is_active);

  RETURN v_result;
END;
$function$;

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
             'is_active', vb.is_active,
             'region', vb.region,
             'operating_hours', vb.operating_hours,
             'items_type', vb.items_type,
             'payment_method', vb.payment_method,
             'banks', vb.banks,
             'notify_by_email', vb.notify_by_email,
             'notify_by_whatsapp', vb.notify_by_whatsapp
           ) ORDER BY vb.city, vb.branch_name) AS branches
    FROM qvm_new_apps.vendor_branches vb
    WHERE vb.vendor_id = vid.vendor_id
      AND (NOT p_active_only OR vb.is_active)
  ) b ON true;

  RETURN v_result;
END;
$function$;
