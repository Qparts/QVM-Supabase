-- Synced from QVM/test branch applied migration history (version 20260706142552, name: vendor_type_and_receives_quotations_in_crud)
-- Extend create_vendor/save_vendor to persist the new controlled vendor_type_id
-- and receives_quotations flag added in the vendor-branches/roles migration.

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

  v_region := CASE WHEN p_vendor ? 'region' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'region') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;
  v_brands := CASE WHEN p_vendor ? 'brands' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'brands') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;

  -- operating_hours is now optional
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
    vendor_name, vendor_type, vendor_type_id, receives_quotations, region, operating_hours, brands, items_type,
    payment_method, tax_number, commercial_registeration_number,
    bank_name, bank_account, alternative_account, bank_and_cr_files,
    zoho_name, email, phone_numbers, bank_accounts, created_at, updated_at
  ) VALUES (
    v_vendor_name, v_vendor_type, v_vendor_type_id, v_receives_quotations, v_region, v_operating_hours, v_brands, v_items_type,
    v_payment_method, v_tax, v_cr,
    v_bank_name, v_bank_account, v_alternative_account, v_attachments,
    v_zoho_name, v_email, v_phone_numbers, v_bank_accounts, now(), now()
  ) RETURNING vendor_id INTO new_id;

  RETURN jsonb_build_object('status','success','vendor_id', new_id);
END;
$function$;

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

  -- Extract new values from payload
  new_vendor_name := COALESCE(NULLIF(p_vendor->>'vendor_name', ''), v_existing.vendor_name);
  new_vendor_type := COALESCE(NULLIF(p_vendor->>'vendor_type', ''), v_existing.vendor_type);
  new_vendor_type_id := COALESCE(NULLIF(p_vendor->>'vendor_type_id', '')::integer, v_existing.vendor_type_id);
  new_receives_quotations := COALESCE((p_vendor->>'receives_quotations')::boolean, v_existing.receives_quotations);

  new_region := COALESCE(
    CASE WHEN p_vendor ? 'region' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'region') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_existing.region
  );

  new_brands := COALESCE(
    CASE WHEN p_vendor ? 'brands' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'brands') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_existing.brands
  );

  new_payment_method := COALESCE(
    CASE
      WHEN p_vendor ? 'payment_methods' AND jsonb_typeof(p_vendor->'payment_methods')='array' THEN
        (SELECT string_agg(trim(x), ', ') FROM jsonb_array_elements_text(p_vendor->'payment_methods') x WHERE trim(x) <> '')
      WHEN p_vendor ? 'payment_method' THEN NULLIF(p_vendor->>'payment_method','')
      ELSE NULL END,
    v_existing.payment_method
  );

  new_operating_hours := COALESCE(
    CASE WHEN p_vendor ? 'operating_hours' THEN p_vendor->'operating_hours' ELSE NULL END,
    v_existing.operating_hours
  );

  new_items_type := COALESCE(
    CASE WHEN p_vendor ? 'items_type' THEN
      to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'items_type') x WHERE trim(x) <> ''))
    ELSE NULL END,
    v_existing.items_type
  );

  new_cr := COALESCE(NULLIF(p_vendor->>'commercial_registeration_number',''), v_existing.commercial_registeration_number);
  new_tax := COALESCE(NULLIF(p_vendor->>'tax_number',''), v_existing.tax_number);

  new_bank_accounts := COALESCE(
    CASE WHEN p_vendor ? 'bank_accounts' THEN p_vendor->'bank_accounts' ELSE NULL END,
    v_existing.bank_accounts
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
    new_bank_name := COALESCE(NULLIF(p_vendor->>'bank_name',''), v_existing.bank_name);
    new_bank_account := COALESCE(NULLIF(p_vendor->>'bank_account',''), v_existing.bank_account);
    new_alternative_account := COALESCE(NULLIF(p_vendor->>'alternative_account',''), v_existing.alternative_account);
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
    v_existing.bank_and_cr_files
  );

  -- Track changed fields
  IF new_vendor_name IS DISTINCT FROM v_existing.vendor_name THEN v_changed := array_append(v_changed, 'vendor_name'); END IF;
  IF new_vendor_type IS DISTINCT FROM v_existing.vendor_type THEN v_changed := array_append(v_changed, 'vendor_type'); END IF;
  IF new_vendor_type_id IS DISTINCT FROM v_existing.vendor_type_id THEN v_changed := array_append(v_changed, 'vendor_type_id'); END IF;
  IF new_receives_quotations IS DISTINCT FROM v_existing.receives_quotations THEN v_changed := array_append(v_changed, 'receives_quotations'); END IF;
  IF new_region IS DISTINCT FROM v_existing.region THEN v_changed := array_append(v_changed, 'region'); END IF;
  IF new_brands IS DISTINCT FROM v_existing.brands THEN v_changed := array_append(v_changed, 'brands'); END IF;
  IF new_payment_method IS DISTINCT FROM v_existing.payment_method THEN v_changed := array_append(v_changed, 'payment_method'); END IF;
  IF new_operating_hours IS DISTINCT FROM v_existing.operating_hours THEN v_changed := array_append(v_changed, 'operating_hours'); END IF;
  IF new_items_type IS DISTINCT FROM v_existing.items_type THEN v_changed := array_append(v_changed, 'items_type'); END IF;
  IF new_cr IS DISTINCT FROM v_existing.commercial_registeration_number THEN v_changed := array_append(v_changed, 'commercial_registeration_number'); END IF;
  IF new_tax IS DISTINCT FROM v_existing.tax_number THEN v_changed := array_append(v_changed, 'tax_number'); END IF;
  IF new_bank_name IS DISTINCT FROM v_existing.bank_name THEN v_changed := array_append(v_changed, 'bank_name'); END IF;
  IF new_bank_account IS DISTINCT FROM v_existing.bank_account THEN v_changed := array_append(v_changed, 'bank_account'); END IF;
  IF new_alternative_account IS DISTINCT FROM v_existing.alternative_account THEN v_changed := array_append(v_changed, 'alternative_account'); END IF;
  IF new_zoho_name IS DISTINCT FROM v_existing.zoho_name THEN v_changed := array_append(v_changed, 'zoho_name'); END IF;
  IF new_email IS DISTINCT FROM v_existing.email THEN v_changed := array_append(v_changed, 'email'); END IF;
  IF new_phone_numbers IS DISTINCT FROM v_existing.phone_numbers THEN v_changed := array_append(v_changed, 'phone_numbers'); END IF;
  IF new_bank_accounts IS DISTINCT FROM v_existing.bank_accounts THEN v_changed := array_append(v_changed, 'bank_accounts'); END IF;
  IF new_attachments IS DISTINCT FROM v_existing.bank_and_cr_files THEN v_changed := array_append(v_changed, 'bank_and_cr_files'); END IF;

  UPDATE qvm_new_apps.vendors
  SET vendor_name = new_vendor_name,
      vendor_type = new_vendor_type,
      vendor_type_id = new_vendor_type_id,
      receives_quotations = new_receives_quotations,
      region = new_region,
      operating_hours = new_operating_hours,
      brands = new_brands,
      items_type = new_items_type,
      payment_method = new_payment_method,
      tax_number = new_tax,
      commercial_registeration_number = new_cr,
      bank_name = new_bank_name,
      bank_account = new_bank_account,
      alternative_account = new_alternative_account,
      bank_and_cr_files = new_attachments,
      zoho_name = new_zoho_name,
      email = new_email,
      phone_numbers = new_phone_numbers,
      bank_accounts = new_bank_accounts,
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
;
