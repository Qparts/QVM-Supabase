-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Single-transaction vendor+branches creation for the admin "Add New Vendor" flow. Wraps what
-- was previously a sequence of separate create_vendor / create_vendor_branch / (update banks) /
-- set_vendor_preferred_branch RPC calls into one function body, so a failure partway through
-- (e.g. a bad branch payload) rolls back the whole thing instead of leaving a vendor with no
-- branches, or branches with no preferred_branch_id set. Mirrors the field handling of those
-- existing RPCs exactly (see create_vendor, create_vendor_branch, set_vendor_preferred_branch).
--
-- Auth-user creation (via the Admin API / GoTrue) isn't part of this transaction since it isn't
-- a plain SQL write - the create_vendor_with_user edge function compensates for that separately
-- by deleting what this function created if the user step fails afterward.

CREATE OR REPLACE FUNCTION public.create_vendor_with_branches(p_user_id uuid, p_vendor jsonb, p_branches jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_vendor_id integer;
  v_vendor_name text;
  v_vendor_type text;
  v_branch jsonb;
  v_branch_id bigint;
  v_first_branch_id bigint;
  v_branch_ids jsonb := '[]'::jsonb;
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

  IF jsonb_array_length(COALESCE(p_branches, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'At least one branch is required';
  END IF;

  INSERT INTO qvm_new_apps.vendors (
    vendor_name, vendor_type, vendor_type_id, receives_quotations,
    tax_number, commercial_registeration_number,
    zoho_name, email, phone_numbers, created_at, updated_at
  ) VALUES (
    v_vendor_name,
    v_vendor_type,
    NULLIF(p_vendor->>'vendor_type_id', '')::integer,
    COALESCE((p_vendor->>'receives_quotations')::boolean, true),
    NULLIF(p_vendor->>'tax_number',''),
    NULLIF(p_vendor->>'commercial_registeration_number',''),
    NULLIF(p_vendor->>'zoho_name',''),
    NULLIF(p_vendor->>'email',''),
    CASE WHEN p_vendor ? 'phone_numbers' THEN to_jsonb(ARRAY(SELECT trim(x) FROM jsonb_array_elements_text(p_vendor->'phone_numbers') x WHERE trim(x) <> '')) ELSE NULL END,
    now(), now()
  ) RETURNING vendor_id INTO v_vendor_id;

  FOR v_branch IN SELECT * FROM jsonb_array_elements(p_branches)
  LOOP
    IF NULLIF(trim(v_branch->>'branch_name'), '') IS NULL OR NULLIF(trim(v_branch->>'city'), '') IS NULL THEN
      RAISE EXCEPTION 'branch_name and city are required for every branch';
    END IF;

    INSERT INTO qvm_new_apps.vendor_branches (
      vendor_id, branch_name, city, phone, location_lat, location_lng, address, brands, categories, is_active,
      region, operating_hours, items_type, payment_method, banks,
      location, discount_percent, notify_by_email, notify_by_whatsapp
    ) VALUES (
      v_vendor_id,
      v_branch->>'branch_name',
      v_branch->>'city',
      NULLIF(trim(v_branch->>'phone'), ''),
      NULLIF(v_branch->>'location_lat', '')::double precision,
      NULLIF(v_branch->>'location_lng', '')::double precision,
      v_branch->>'address',
      COALESCE(v_branch->'brands', '[]'::jsonb),
      COALESCE(v_branch->'categories', '[]'::jsonb),
      COALESCE((v_branch->>'is_active')::boolean, true),
      CASE WHEN v_branch ? 'region' THEN v_branch->'region' ELSE NULL END,
      CASE WHEN v_branch ? 'operating_hours' THEN v_branch->'operating_hours' ELSE NULL END,
      CASE WHEN v_branch ? 'items_type' THEN v_branch->'items_type' ELSE NULL END,
      NULLIF(v_branch->>'payment_method', ''),
      COALESCE(v_branch->'banks', '[]'::jsonb),
      NULLIF(v_branch->>'location', ''),
      NULLIF(v_branch->>'discount_percent', '')::double precision,
      COALESCE((v_branch->>'notify_by_email')::boolean, true),
      COALESCE((v_branch->>'notify_by_whatsapp')::boolean, false)
    )
    RETURNING vendor_branch_id INTO v_branch_id;

    IF v_first_branch_id IS NULL THEN v_first_branch_id := v_branch_id; END IF;
    v_branch_ids := v_branch_ids || to_jsonb(v_branch_id);
  END LOOP;

  UPDATE qvm_new_apps.vendors SET preferred_branch_id = v_first_branch_id WHERE vendor_id = v_vendor_id;

  RETURN jsonb_build_object('status', 'success', 'vendor_id', v_vendor_id, 'branch_ids', v_branch_ids);
END;
$function$;
