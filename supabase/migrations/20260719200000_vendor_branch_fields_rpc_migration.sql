-- Step 3/4 of moving branch-specific fields from vendors to vendor_branches.
-- Repoints every RPC that reads/writes the migrated fields at vendor_branches.
-- vendors keeps: vendor_name, vendor_type(_id), receives_quotations, tax_number,
-- commercial_registeration_number, zoho_name, email, phone_numbers, preferred_branch_id.

-- ============================================================================
-- list_vendor_filters: distinct payment_method/brands/region now come from vendor_branches.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.list_vendor_filters()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_vendor_types jsonb;
  v_payment_methods jsonb;
  v_brands jsonb;
  v_regions jsonb;
BEGIN
  -- Vendor Types (unchanged: stays on vendors)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_vendor_types
  FROM (
    SELECT DISTINCT initcap(btrim(v.vendor_type)) AS name
    FROM qvm_new_apps.vendors v
    WHERE v.vendor_type IS NOT NULL AND btrim(v.vendor_type) <> ''
  ) s;

  -- Payment Methods (CSV -> distinct -> title case), now from vendor_branches
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_payment_methods
  FROM (
    SELECT DISTINCT initcap(nm) AS name
    FROM (
      SELECT lower(btrim(x)) AS nm
      FROM qvm_new_apps.vendor_branches vb,
           regexp_split_to_table(COALESCE(vb.payment_method, ''), '\s*,\s*') x
      WHERE x IS NOT NULL AND btrim(x) <> ''
    ) t
  ) d;

  -- Brands: ensure array before expanding, now from vendor_branches
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_brands
  FROM (
    SELECT DISTINCT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendor_branches vb,
         jsonb_array_elements_text(CASE WHEN jsonb_typeof(vb.brands) = 'array' THEN vb.brands ELSE '[]'::jsonb END) AS elem
  ) b;

  -- Regions: ensure array before expanding, now from vendor_branches
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_regions
  FROM (
    SELECT DISTINCT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendor_branches vb,
         jsonb_array_elements_text(CASE WHEN jsonb_typeof(vb.region) = 'array' THEN vb.region ELSE '[]'::jsonb END) AS elem
  ) r;

  RETURN jsonb_build_object(
    'vendor_types', v_vendor_types,
    'payment_methods', v_payment_methods,
    'brands', v_brands,
    'regions', v_regions
  );
END;
$function$;

-- ============================================================================
-- get_vendors_dashboard: join the vendor's preferred branch for the migrated fields.
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
           pb.bank_name AS pb_bank_name, pb.bank_account AS pb_bank_account,
           pb.alternative_account AS pb_alternative_account, pb.bank_accounts AS pb_bank_accounts,
           pb.bank_account_name AS pb_bank_account_name, pb.bank_iban AS pb_bank_iban,
           pb.bank_and_cr_files AS pb_bank_and_cr_files, pb.location AS pb_location,
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
      v.pb_bank_name AS bank_name,
      v.pb_bank_account AS bank_account,
      v.pb_alternative_account AS alternative_account,
      v.pb_bank_and_cr_files AS bank_and_cr_files,
      v.pb_location AS location,
      v.pb_discount_percent AS discount_percent,
      v.email,
      v.phone_numbers,
      v.pb_bank_accounts AS bank_accounts,
      v.pb_bank_account_name AS bank_account_name,
      v.pb_bank_iban AS bank_iban,
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
-- save_vendor: vendor-level fields still update vendors; migrated fields now update
-- the vendor's preferred branch (falling back to its first branch if no preferred set).
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
  v_branch qvm_new_apps.vendor_branches%ROWTYPE;
  v_target_branch_id bigint;
  v_changed text[] := ARRAY[]::text[];
  new_vendor_name text;
  new_vendor_type text;
  new_vendor_type_id integer;
  new_receives_quotations boolean;
  new_notify_by_email boolean;
  new_notify_by_whatsapp boolean;
  new_region jsonb;
  new_brands jsonb;
  new_payment_method text;
  new_operating_hours jsonb;
  new_items_type jsonb;
  new_cr text;
  new_tax text;
  new_bank_accounts jsonb;
  new_bank_name text;
  new_bank_account text;
  new_alternative_account text;
  new_zoho_name text;
  new_email text;
  new_phone_numbers jsonb;
  new_attachments text;
BEGIN
  -- Authorization (internal or specific roles)
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

  v_target_branch_id := v_existing.preferred_branch_id;
  IF v_target_branch_id IS NULL THEN
    SELECT vendor_branch_id INTO v_target_branch_id
    FROM qvm_new_apps.vendor_branches
    WHERE vendor_id = p_vendor_id
    ORDER BY vendor_branch_id ASC
    LIMIT 1;
  END IF;

  IF v_target_branch_id IS NOT NULL THEN
    SELECT * INTO v_branch FROM qvm_new_apps.vendor_branches WHERE vendor_branch_id = v_target_branch_id FOR UPDATE;
  END IF;

  -- Extract new values from payload (vendor-level fields unchanged)
  new_vendor_name := COALESCE(NULLIF(p_vendor->>'vendor_name', ''), v_existing.vendor_name);
  new_vendor_type := COALESCE(NULLIF(p_vendor->>'vendor_type', ''), v_existing.vendor_type);
  new_vendor_type_id := COALESCE(NULLIF(p_vendor->>'vendor_type_id', '')::integer, v_existing.vendor_type_id);
  new_receives_quotations := COALESCE((p_vendor->>'receives_quotations')::boolean, v_existing.receives_quotations);

  -- Migrated fields: compare/default against the target branch (if any) instead of vendors
  new_notify_by_email := COALESCE((p_vendor->>'notify_by_email')::boolean, v_branch.notify_by_email, true);
  new_notify_by_whatsapp := COALESCE((p_vendor->>'notify_by_whatsapp')::boolean, v_branch.notify_by_whatsapp, false);

  new_region := COALESCE(
    CASE WHEN p_vendor ? 'region' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'region') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_branch.region
  );

  new_brands := COALESCE(
    CASE WHEN p_vendor ? 'brands' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'brands') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_branch.brands
  );

  new_payment_method := COALESCE(
    CASE
      WHEN p_vendor ? 'payment_methods' AND jsonb_typeof(p_vendor->'payment_methods')='array' THEN
        (SELECT string_agg(trim(x), ', ') FROM jsonb_array_elements_text(p_vendor->'payment_methods') x WHERE trim(x) <> '')
      WHEN p_vendor ? 'payment_method' THEN NULLIF(p_vendor->>'payment_method','')
      ELSE NULL END,
    v_branch.payment_method
  );

  new_operating_hours := COALESCE(
    CASE WHEN p_vendor ? 'operating_hours' THEN p_vendor->'operating_hours' ELSE NULL END,
    v_branch.operating_hours
  );

  new_items_type := COALESCE(
    CASE WHEN p_vendor ? 'items_type' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'items_type') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_branch.items_type
  );

  new_cr := COALESCE(NULLIF(p_vendor->>'commercial_registeration_number',''), v_existing.commercial_registeration_number);
  new_tax := COALESCE(NULLIF(p_vendor->>'tax_number',''), v_existing.tax_number);

  new_bank_accounts := COALESCE(
    CASE WHEN p_vendor ? 'bank_accounts' THEN p_vendor->'bank_accounts' ELSE NULL END,
    v_branch.bank_accounts
  );

  -- Keep legacy columns in sync from bank_accounts if present; else allow direct text updates
  IF new_bank_accounts IS NOT NULL THEN
    new_bank_name := (
      SELECT string_agg(coalesce(trim(elem->>'name'),''), ', ')
      FROM jsonb_array_elements(new_bank_accounts) elem
      WHERE coalesce(trim(elem->>'name'), '') <> ''
    );
    new_bank_account := (
      SELECT string_agg(coalesce(trim(elem->>'main'),''), ', ')
      FROM jsonb_array_elements(new_bank_accounts) elem
      WHERE coalesce(trim(elem->>'main'), '') <> ''
    );
    new_alternative_account := (
      SELECT string_agg(coalesce(trim(elem->>'alt'),''), ', ')
      FROM jsonb_array_elements(new_bank_accounts) elem
      WHERE coalesce(trim(elem->>'alt'), '') <> ''
    );
  ELSE
    new_bank_name := COALESCE(NULLIF(p_vendor->>'bank_name',''), v_branch.bank_name);
    new_bank_account := COALESCE(NULLIF(p_vendor->>'bank_account',''), v_branch.bank_account);
    new_alternative_account := COALESCE(NULLIF(p_vendor->>'alternative_account',''), v_branch.alternative_account);
  END IF;

  new_zoho_name := COALESCE(NULLIF(p_vendor->>'zoho_name',''), v_existing.zoho_name);
  new_email := COALESCE(NULLIF(p_vendor->>'email',''), v_existing.email);

  new_phone_numbers := COALESCE(
    CASE WHEN p_vendor ? 'phone_numbers' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'phone_numbers') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_existing.phone_numbers
  );

  new_attachments := COALESCE(
    CASE WHEN p_vendor ? 'attachments' THEN
      (SELECT jsonb_agg(elem)::text FROM jsonb_array_elements(p_vendor->'attachments') elem)
    ELSE NULL END,
    v_branch.bank_and_cr_files
  );

  -- Track changed fields
  IF new_vendor_name IS DISTINCT FROM v_existing.vendor_name THEN v_changed := array_append(v_changed, 'vendor_name'); END IF;
  IF new_vendor_type IS DISTINCT FROM v_existing.vendor_type THEN v_changed := array_append(v_changed, 'vendor_type'); END IF;
  IF new_vendor_type_id IS DISTINCT FROM v_existing.vendor_type_id THEN v_changed := array_append(v_changed, 'vendor_type_id'); END IF;
  IF new_receives_quotations IS DISTINCT FROM v_existing.receives_quotations THEN v_changed := array_append(v_changed, 'receives_quotations'); END IF;
  IF new_notify_by_email IS DISTINCT FROM v_branch.notify_by_email THEN v_changed := array_append(v_changed, 'notify_by_email'); END IF;
  IF new_notify_by_whatsapp IS DISTINCT FROM v_branch.notify_by_whatsapp THEN v_changed := array_append(v_changed, 'notify_by_whatsapp'); END IF;
  IF new_region IS DISTINCT FROM v_branch.region THEN v_changed := array_append(v_changed, 'region'); END IF;
  IF new_brands IS DISTINCT FROM v_branch.brands THEN v_changed := array_append(v_changed, 'brands'); END IF;
  IF new_payment_method IS DISTINCT FROM v_branch.payment_method THEN v_changed := array_append(v_changed, 'payment_method'); END IF;
  IF new_operating_hours IS DISTINCT FROM v_branch.operating_hours THEN v_changed := array_append(v_changed, 'operating_hours'); END IF;
  IF new_items_type IS DISTINCT FROM v_branch.items_type THEN v_changed := array_append(v_changed, 'items_type'); END IF;
  IF new_cr IS DISTINCT FROM v_existing.commercial_registeration_number THEN v_changed := array_append(v_changed, 'commercial_registeration_number'); END IF;
  IF new_tax IS DISTINCT FROM v_existing.tax_number THEN v_changed := array_append(v_changed, 'tax_number'); END IF;
  IF new_bank_name IS DISTINCT FROM v_branch.bank_name THEN v_changed := array_append(v_changed, 'bank_name'); END IF;
  IF new_bank_account IS DISTINCT FROM v_branch.bank_account THEN v_changed := array_append(v_changed, 'bank_account'); END IF;
  IF new_alternative_account IS DISTINCT FROM v_branch.alternative_account THEN v_changed := array_append(v_changed, 'alternative_account'); END IF;
  IF new_zoho_name IS DISTINCT FROM v_existing.zoho_name THEN v_changed := array_append(v_changed, 'zoho_name'); END IF;
  IF new_email IS DISTINCT FROM v_existing.email THEN v_changed := array_append(v_changed, 'email'); END IF;
  IF new_phone_numbers IS DISTINCT FROM v_existing.phone_numbers THEN v_changed := array_append(v_changed, 'phone_numbers'); END IF;
  IF new_bank_accounts IS DISTINCT FROM v_branch.bank_accounts THEN v_changed := array_append(v_changed, 'bank_accounts'); END IF;
  IF new_attachments IS DISTINCT FROM v_branch.bank_and_cr_files THEN v_changed := array_append(v_changed, 'bank_and_cr_files'); END IF;

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

  IF v_target_branch_id IS NOT NULL THEN
    UPDATE qvm_new_apps.vendor_branches
    SET notify_by_email = new_notify_by_email,
        notify_by_whatsapp = new_notify_by_whatsapp,
        region = new_region,
        operating_hours = new_operating_hours,
        brands = new_brands,
        items_type = new_items_type,
        payment_method = new_payment_method,
        bank_name = new_bank_name,
        bank_account = new_bank_account,
        alternative_account = new_alternative_account,
        bank_and_cr_files = new_attachments,
        bank_accounts = new_bank_accounts,
        updated_at = now()
    WHERE vendor_branch_id = v_target_branch_id;
  END IF;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Vendor updated successfully',
    'vendor_id', p_vendor_id,
    'changed', v_changed
  );
END;
$function$;

-- ============================================================================
-- create_vendor: create the vendor row (non-migrated fields only), then atomically create
-- its default branch holding the migrated fields, and set preferred_branch_id.
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
  new_branch_id bigint;
  v_vendor_name text;
  v_vendor_type text;
  v_vendor_type_id integer;
  v_receives_quotations boolean;
  v_notify_by_email boolean;
  v_notify_by_whatsapp boolean;
  v_region jsonb;
  v_brands jsonb;
  v_payment_method text;
  v_operating_hours jsonb;
  v_items_type jsonb;
  v_cr text;
  v_tax text;
  v_bank_accounts jsonb;
  v_bank_name text;
  v_bank_account text;
  v_alternative_account text;
  v_zoho_name text;
  v_email text;
  v_phone_numbers jsonb;
  v_attachments text;
  v_city text;
BEGIN
  -- Authorization (internal or specific roles)
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

  -- Required validations (server-side minimal): name, type, region, brands, payment_methods
  v_vendor_name := NULLIF(p_vendor->>'vendor_name', '');
  v_vendor_type := NULLIF(p_vendor->>'vendor_type', '');
  IF v_vendor_name IS NULL OR v_vendor_type IS NULL THEN
    RAISE EXCEPTION 'Missing required fields: vendor_name, vendor_type';
  END IF;

  v_vendor_type_id := NULLIF(p_vendor->>'vendor_type_id', '')::integer;
  v_receives_quotations := COALESCE((p_vendor->>'receives_quotations')::boolean, true);
  v_notify_by_email := COALESCE((p_vendor->>'notify_by_email')::boolean, true);
  v_notify_by_whatsapp := COALESCE((p_vendor->>'notify_by_whatsapp')::boolean, false);

  v_region := CASE WHEN p_vendor ? 'region' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'region') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;
  v_brands := CASE WHEN p_vendor ? 'brands' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'brands') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;

  -- operating_hours is optional
  v_operating_hours := CASE WHEN p_vendor ? 'operating_hours' THEN p_vendor->'operating_hours' ELSE NULL END;

  v_payment_method := CASE
    WHEN p_vendor ? 'payment_methods' AND jsonb_typeof(p_vendor->'payment_methods')='array' THEN (
      SELECT string_agg(trim(x), ', ') FROM jsonb_array_elements_text(p_vendor->'payment_methods') x WHERE trim(x) <> ''
    )
    WHEN p_vendor ? 'payment_method' THEN NULLIF(p_vendor->>'payment_method','')
    ELSE NULL
  END;
  IF COALESCE(trim(v_payment_method), '') = '' THEN
    RAISE EXCEPTION 'Missing required field: payment_methods';
  END IF;

  v_items_type := CASE WHEN p_vendor ? 'items_type' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'items_type') x WHERE trim(x) <> '')) ELSE NULL END;
  v_cr := NULLIF(p_vendor->>'commercial_registeration_number','');
  v_tax := NULLIF(p_vendor->>'tax_number','');
  v_bank_accounts := CASE WHEN p_vendor ? 'bank_accounts' THEN p_vendor->'bank_accounts' ELSE NULL END;
  IF v_bank_accounts IS NOT NULL THEN
    v_bank_name := (
      SELECT string_agg(coalesce(trim(elem->>'name'),''), ', ') FROM jsonb_array_elements(v_bank_accounts) elem WHERE coalesce(trim(elem->>'name'), '') <> ''
    );
    v_bank_account := (
      SELECT string_agg(coalesce(trim(elem->>'main'),''), ', ') FROM jsonb_array_elements(v_bank_accounts) elem WHERE coalesce(trim(elem->>'main'), '') <> ''
    );
    v_alternative_account := (
      SELECT string_agg(coalesce(trim(elem->>'alt'),''), ', ') FROM jsonb_array_elements(v_bank_accounts) elem WHERE coalesce(trim(elem->>'alt'), '') <> ''
    );
  ELSE
    v_bank_name := NULLIF(p_vendor->>'bank_name','');
    v_bank_account := NULLIF(p_vendor->>'bank_account','');
    v_alternative_account := NULLIF(p_vendor->>'alternative_account','');
  END IF;

  v_zoho_name := NULLIF(p_vendor->>'zoho_name','');
  v_email := NULLIF(p_vendor->>'email','');
  v_phone_numbers := CASE WHEN p_vendor ? 'phone_numbers' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'phone_numbers') x WHERE trim(x) <> '')) ELSE NULL END;
  v_attachments := CASE WHEN p_vendor ? 'attachments' THEN (SELECT jsonb_agg(elem)::text FROM jsonb_array_elements(p_vendor->'attachments') elem) ELSE NULL END;

  INSERT INTO qvm_new_apps.vendors (
    vendor_name, vendor_type, vendor_type_id, receives_quotations,
    tax_number, commercial_registeration_number,
    zoho_name, email, phone_numbers, created_at, updated_at
  ) VALUES (
    v_vendor_name, v_vendor_type, v_vendor_type_id, v_receives_quotations,
    v_tax, v_cr,
    v_zoho_name, v_email, v_phone_numbers, now(), now()
  ) RETURNING vendor_id INTO new_id;

  -- The create form doesn't collect branch_name/city yet, so default the same way the
  -- backfill migration did for pre-existing branchless vendors.
  v_city := COALESCE(NULLIF(btrim(v_region->>0), ''), 'Unknown');

  INSERT INTO qvm_new_apps.vendor_branches (
    vendor_id, branch_name, city, brands, region, operating_hours, items_type,
    payment_method, bank_name, bank_account, alternative_account, bank_accounts,
    bank_and_cr_files, notify_by_email, notify_by_whatsapp, is_active
  ) VALUES (
    new_id, 'الفرع الرئيسي', v_city, v_brands, v_region, v_operating_hours, v_items_type,
    v_payment_method, v_bank_name, v_bank_account, v_alternative_account, v_bank_accounts,
    v_attachments, v_notify_by_email, v_notify_by_whatsapp, true
  ) RETURNING vendor_branch_id INTO new_branch_id;

  UPDATE qvm_new_apps.vendors SET preferred_branch_id = new_branch_id WHERE vendor_id = new_id;

  RETURN jsonb_build_object('status','success','vendor_id', new_id, 'vendor_branch_id', new_branch_id);
END;
$function$;

-- ============================================================================
-- create_vendor_branch / update_vendor_branch: extend the existing partial-update pattern
-- to also accept the newly-migrated fields, so branch-level editing works going forward.
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
    region, operating_hours, items_type, payment_method,
    bank_name, bank_account, alternative_account, bank_accounts, bank_account_name, bank_iban,
    bank_and_cr_files, location, discount_percent, notify_by_email, notify_by_whatsapp
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
    NULLIF(p_branch->>'bank_name', ''),
    NULLIF(p_branch->>'bank_account', ''),
    NULLIF(p_branch->>'alternative_account', ''),
    CASE WHEN p_branch ? 'bank_accounts' THEN p_branch->'bank_accounts' ELSE NULL END,
    NULLIF(p_branch->>'bank_account_name', ''),
    NULLIF(p_branch->>'bank_iban', ''),
    NULLIF(p_branch->>'bank_and_cr_files', ''),
    NULLIF(p_branch->>'location', ''),
    NULLIF(p_branch->>'discount_percent', '')::double precision,
    COALESCE((p_branch->>'notify_by_email')::boolean, true),
    COALESCE((p_branch->>'notify_by_whatsapp')::boolean, false)
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
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
    bank_name = CASE WHEN p_branch ? 'bank_name' THEN NULLIF(p_branch->>'bank_name', '') ELSE bank_name END,
    bank_account = CASE WHEN p_branch ? 'bank_account' THEN NULLIF(p_branch->>'bank_account', '') ELSE bank_account END,
    alternative_account = CASE WHEN p_branch ? 'alternative_account' THEN NULLIF(p_branch->>'alternative_account', '') ELSE alternative_account END,
    bank_accounts = CASE WHEN p_branch ? 'bank_accounts' THEN p_branch->'bank_accounts' ELSE bank_accounts END,
    bank_account_name = CASE WHEN p_branch ? 'bank_account_name' THEN NULLIF(p_branch->>'bank_account_name', '') ELSE bank_account_name END,
    bank_iban = CASE WHEN p_branch ? 'bank_iban' THEN NULLIF(p_branch->>'bank_iban', '') ELSE bank_iban END,
    bank_and_cr_files = CASE WHEN p_branch ? 'bank_and_cr_files' THEN NULLIF(p_branch->>'bank_and_cr_files', '') ELSE bank_and_cr_files END,
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
-- get_vendor_notification_channels: signature unchanged (called externally by n8n with
-- p_vendor_id only). Now resolves via the vendor's preferred branch instead of vendors
-- directly.
-- ============================================================================
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_notification_channels(p_vendor_id integer)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_email boolean;
  v_whatsapp boolean;
  v_result text[] := ARRAY[]::text[];
BEGIN
  SELECT vb.notify_by_email, vb.notify_by_whatsapp INTO v_email, v_whatsapp
  FROM qvm_new_apps.vendors v
  JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = v.preferred_branch_id
  WHERE v.vendor_id = p_vendor_id;

  IF v_email THEN v_result := array_append(v_result, 'email'); END IF;
  IF v_whatsapp THEN v_result := array_append(v_result, 'whatsapp'); END IF;
  IF array_length(v_result, 1) IS NULL THEN v_result := ARRAY['email']; END IF;

  RETURN v_result;
END;
$function$;
