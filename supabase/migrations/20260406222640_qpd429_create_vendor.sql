-- Synced from QVM/test branch applied migration history (version 20260406222640, name: qpd429_create_vendor)
BEGIN;

SET search_path TO qvm_new_apps, public;

-- Create vendor RPC for registration
CREATE OR REPLACE FUNCTION public.create_vendor(
  p_user_id uuid,
  p_vendor jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  new_id integer;
  v_vendor_name text;
  v_vendor_type text;
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

  -- Required validations (server-side minimal): name, type, region, brands, payment_methods, operating_hours
  v_vendor_name := NULLIF(p_vendor->>'vendor_name', '');
  v_vendor_type := NULLIF(p_vendor->>'vendor_type', '');
  IF v_vendor_name IS NULL OR v_vendor_type IS NULL THEN
    RAISE EXCEPTION 'Missing required fields: vendor_name, vendor_type';
  END IF;

  v_region := CASE WHEN p_vendor ? 'region' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'region') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;
  v_brands := CASE WHEN p_vendor ? 'brands' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'brands') x WHERE trim(x) <> '')) ELSE '[]'::jsonb END;
  v_operating_hours := CASE WHEN p_vendor ? 'operating_hours' THEN p_vendor->'operating_hours' ELSE NULL END;
  IF v_operating_hours IS NULL THEN
    RAISE EXCEPTION 'Missing required field: operating_hours';
  END IF;

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
    vendor_name, vendor_type, region, operating_hours, brands, items_type,
    payment_method, tax_number, commercial_registeration_number,
    bank_name, bank_account, alternative_account, bank_and_cr_files,
    zoho_name, email, phone_numbers, bank_accounts, created_at, updated_at
  ) VALUES (
    v_vendor_name, v_vendor_type, v_region, v_operating_hours, v_brands, v_items_type,
    v_payment_method, v_tax, v_cr,
    v_bank_name, v_bank_account, v_alternative_account, v_attachments,
    v_zoho_name, v_email, v_phone_numbers, v_bank_accounts, now(), now()
  ) RETURNING vendor_id INTO new_id;

  RETURN jsonb_build_object('status','success','vendor_id', new_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_vendor(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_vendor(uuid, jsonb) TO authenticated;

COMMIT;;
