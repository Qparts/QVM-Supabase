-- A vendor branch names its payment term.
--
-- The payment term a vendor branch gives Qparts (`vendor_branches.credit_term_days`, with
-- `account_type` credit or cash) could only be set from the Vendors & Branches tree by Qparts.
-- The vendor's own admin now sets it from the vendor dashboard's branches page: the branch
-- listings carry the account fields, and the branch create / update functions accept the account
-- type and the term. The credit limit is listed but not writable here — what Qparts grants a
-- vendor stays Qparts's to set. Both writers keep their guard: an internal user, or the vendor's
-- own admin for that vendor.

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
           'notify_by_whatsapp', vb.notify_by_whatsapp,
           'auto_receive_rfqs', COALESCE(vb.auto_receive_rfqs, false),
           'account_type', vb.account_type,
           'credit_limit', vb.credit_limit,
           'credit_term_days', vb.credit_term_days
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
             'notify_by_whatsapp', vb.notify_by_whatsapp,
           'auto_receive_rfqs', COALESCE(vb.auto_receive_rfqs, false),
           'account_type', vb.account_type,
           'credit_limit', vb.credit_limit,
           'credit_term_days', vb.credit_term_days
           ) ORDER BY vb.city, vb.branch_name) AS branches
    FROM qvm_new_apps.vendor_branches vb
    WHERE vb.vendor_id = vid.vendor_id
      AND (NOT p_active_only OR vb.is_active)
  ) b ON true;

  RETURN v_result;
END;
$function$;

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
  IF p_branch ? 'account_type' AND NULLIF(p_branch->>'account_type', '') IS NOT NULL
     AND p_branch->>'account_type' NOT IN ('credit', 'cash') THEN
    RAISE EXCEPTION 'account_type must be credit or cash';
  END IF;
  IF p_branch ? 'credit_term_days' AND NULLIF(p_branch->>'credit_term_days', '') IS NOT NULL
     AND (p_branch->>'credit_term_days')::int < 0 THEN
    RAISE EXCEPTION 'credit_term_days cannot be negative';
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
    auto_receive_rfqs = COALESCE((p_branch->>'auto_receive_rfqs')::boolean, auto_receive_rfqs),
    -- The branch's payment terms with Qparts: a credit account with a term in days, or cash. The
    -- vendor's admin sets these too; the credit limit stays Qparts's to grant.
    account_type = CASE WHEN p_branch ? 'account_type' THEN NULLIF(p_branch->>'account_type', '') ELSE account_type END,
    credit_term_days = CASE WHEN p_branch ? 'credit_term_days' THEN NULLIF(p_branch->>'credit_term_days', '')::int ELSE credit_term_days END,
    updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

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
  IF NULLIF(p_branch->>'account_type', '') IS NOT NULL AND p_branch->>'account_type' NOT IN ('credit', 'cash') THEN
    RAISE EXCEPTION 'account_type must be credit or cash';
  END IF;
  IF NULLIF(p_branch->>'credit_term_days', '') IS NOT NULL AND (p_branch->>'credit_term_days')::int < 0 THEN
    RAISE EXCEPTION 'credit_term_days cannot be negative';
  END IF;

  INSERT INTO qvm_new_apps.vendor_branches (
    vendor_id, branch_name, city, phone, location_lat, location_lng, address, brands, categories, is_active,
    region, operating_hours, items_type, payment_method, banks,
    location, discount_percent, notify_by_email, notify_by_whatsapp, auto_receive_rfqs,
    account_type, credit_term_days
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
    COALESCE((p_branch->>'notify_by_whatsapp')::boolean, false),
    COALESCE((p_branch->>'auto_receive_rfqs')::boolean, false),
    NULLIF(p_branch->>'account_type', ''),
    NULLIF(p_branch->>'credit_term_days', '')::int
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
END;
$function$;
