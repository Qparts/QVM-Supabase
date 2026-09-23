-- A customer carries its identity and documents; its branches their code, brands, banks and hours;
-- the insurance registry its official numbers.
--
-- The add-customer design mirrors the workshop and vendor ones. The Customer tree's forms now
-- collect the same fields, and an insurance customer's name, tax and register come from the
-- insurance company record, which learns those columns here.
ALTER TABLE qvm_new_apps.end_customers
  ADD COLUMN IF NOT EXISTS name_en text,
  ADD COLUMN IF NOT EXISTS cr_kind text,
  ADD COLUMN IF NOT EXISTS cr_number text;
ALTER TABLE qvm_new_apps.end_customers DROP CONSTRAINT IF EXISTS end_customers_cr_kind_check;
ALTER TABLE qvm_new_apps.end_customers ADD CONSTRAINT end_customers_cr_kind_check CHECK (cr_kind IS NULL OR cr_kind IN ('cr', 'unified'));
ALTER TABLE qvm_new_apps.insurance_companies
  ADD COLUMN IF NOT EXISTS name_en text,
  ADD COLUMN IF NOT EXISTS tax_number text,
  ADD COLUMN IF NOT EXISTS cr_number text;
ALTER TABLE qvm_new_apps.end_customer_branches
  ADD COLUMN IF NOT EXISTS branch_code text,
  ADD COLUMN IF NOT EXISTS brand_ids integer[],
  ADD COLUMN IF NOT EXISTS part_category_ids integer[],
  ADD COLUMN IF NOT EXISTS banks jsonb,
  ADD COLUMN IF NOT EXISTS account_type text,
  ADD COLUMN IF NOT EXISTS credit_limit numeric,
  ADD COLUMN IF NOT EXISTS credit_term_days integer,
  ADD COLUMN IF NOT EXISTS hours_mode text,
  ADD COLUMN IF NOT EXISTS working_hours jsonb;
ALTER TABLE qvm_new_apps.end_customer_branches DROP CONSTRAINT IF EXISTS end_customer_branches_account_type_check;
ALTER TABLE qvm_new_apps.end_customer_branches ADD CONSTRAINT end_customer_branches_account_type_check CHECK (account_type IS NULL OR account_type IN ('credit', 'cash'));
ALTER TABLE qvm_new_apps.end_customer_branches DROP CONSTRAINT IF EXISTS end_customer_branches_hours_mode_check;
ALTER TABLE qvm_new_apps.end_customer_branches ADD CONSTRAINT end_customer_branches_hours_mode_check CHECK (hours_mode IS NULL OR hours_mode IN ('247', 'schedule'));
ALTER TABLE qvm_new_apps.end_customer_addresses ADD COLUMN IF NOT EXISTS address_type text;
ALTER TABLE qvm_new_apps.end_customer_addresses DROP CONSTRAINT IF EXISTS end_customer_addresses_address_type_check;
ALTER TABLE qvm_new_apps.end_customer_addresses ADD CONSTRAINT end_customer_addresses_address_type_check CHECK (address_type IS NULL OR address_type IN ('warehouse', 'showroom', 'office', 'pickup'));

CREATE OR REPLACE FUNCTION qvm_new_apps._apply_end_customer_details(p_end_customer_id bigint, p jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'cr_kind' AND NULLIF(btrim(p->>'cr_kind'), '') IS NOT NULL AND (p->>'cr_kind') NOT IN ('cr', 'unified') THEN
    RAISE EXCEPTION 'Unknown registration kind';
  END IF;
  UPDATE qvm_new_apps.end_customers c
     SET name_en    = CASE WHEN p ? 'name_en' THEN NULLIF(btrim(p->>'name_en'), '') ELSE c.name_en END,
         cr_kind    = CASE WHEN p ? 'cr_kind' THEN NULLIF(btrim(p->>'cr_kind'), '') ELSE c.cr_kind END,
         cr_number  = CASE WHEN p ? 'cr_number' THEN NULLIF(btrim(p->>'cr_number'), '') ELSE c.cr_number END,
         -- An insurance customer's numbers live on the insurance company record.
         tax_number = CASE WHEN p ? 'vat_number' AND c.customer_kind <> 'insurance' THEN NULLIF(btrim(p->>'vat_number'), '') ELSE c.tax_number END,
         updated_at = now()
   WHERE c.end_customer_id = p_end_customer_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_end_customer_details(bigint, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION qvm_new_apps._apply_end_customer_branch_details(p_branch_id bigint, p jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'hours_mode' AND NULLIF(btrim(p->>'hours_mode'), '') IS NOT NULL AND (p->>'hours_mode') NOT IN ('247', 'schedule') THEN
    RAISE EXCEPTION 'Unknown working-hours mode';
  END IF;
  IF p ? 'account_type' AND NULLIF(btrim(p->>'account_type'), '') IS NOT NULL AND (p->>'account_type') NOT IN ('credit', 'cash') THEN
    RAISE EXCEPTION 'Unknown account type';
  END IF;
  UPDATE qvm_new_apps.end_customer_branches b
     SET branch_code       = CASE WHEN p ? 'branch_code' THEN NULLIF(btrim(p->>'branch_code'), '') ELSE b.branch_code END,
         brand_ids         = CASE WHEN p ? 'brand_ids' THEN (SELECT COALESCE(array_agg(x::int), '{}') FROM jsonb_array_elements_text(COALESCE(p->'brand_ids', '[]'::jsonb)) x) ELSE b.brand_ids END,
         part_category_ids = CASE WHEN p ? 'part_category_ids' THEN (SELECT COALESCE(array_agg(x::int), '{}') FROM jsonb_array_elements_text(COALESCE(p->'part_category_ids', '[]'::jsonb)) x) ELSE b.part_category_ids END,
         banks             = CASE WHEN p ? 'banks' THEN COALESCE(p->'banks', '[]'::jsonb) ELSE b.banks END,
         account_type      = CASE WHEN p ? 'account_type' THEN NULLIF(btrim(p->>'account_type'), '') ELSE b.account_type END,
         credit_limit      = CASE WHEN p ? 'credit_limit' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_limit', ''), '[^0-9.]', '', 'g'), '')::numeric ELSE b.credit_limit END,
         credit_term_days  = CASE WHEN p ? 'credit_term_days' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_term_days', ''), '[^0-9]', '', 'g'), '')::int ELSE b.credit_term_days END,
         hours_mode        = CASE WHEN p ? 'hours_mode' THEN NULLIF(btrim(p->>'hours_mode'), '') ELSE b.hours_mode END,
         working_hours     = CASE WHEN p ? 'working_hours' THEN COALESCE(p->'working_hours', '[]'::jsonb) ELSE b.working_hours END,
         updated_at = now()
   WHERE b.end_customer_branch_id = p_branch_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_end_customer_branch_details(bigint, jsonb) FROM PUBLIC;

-- Trailing defaults make new overloads; the old shapes go so a call stays unambiguous.
DROP FUNCTION IF EXISTS public.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean);
DROP FUNCTION IF EXISTS public.admin_upsert_end_customer_branch(bigint, bigint, jsonb, integer, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_end_customer_branch(bigint, bigint, jsonb, integer, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_end_customer(p_end_customer_id bigint DEFAULT NULL::bigint, p_customer_kind text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_insurance_company_id bigint DEFAULT NULL::bigint, p_tax_number text DEFAULT NULL::text, p_contact_person text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_owner_kind text DEFAULT NULL::text, p_owner_id bigint DEFAULT NULL::bigint, p_requires_customer_approval boolean DEFAULT NULL::boolean, p_requires_workshop_approval boolean DEFAULT NULL::boolean, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint := p_end_customer_id;
  v_kind text := lower(btrim(COALESCE(p_customer_kind, '')));
BEGIN
  IF v_id IS NULL THEN
    IF v_kind NOT IN ('individual', 'insurance', 'company', 'government') THEN
      RETURN jsonb_build_object('success', false, 'error', 'Pick what kind of customer this is');
    END IF;
    IF p_owner_kind = 'workshop' AND NOT qvm_new_apps.can_admin_workshop(p_owner_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
    END IF;
    IF p_owner_kind = 'vendor' AND NOT qvm_new_apps.can_admin_vendor(p_owner_id::integer) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
    END IF;
    IF p_owner_kind IS NULL AND NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
      RETURN jsonb_build_object('success', false, 'error', 'A customer needs a workshop or a vendor');
    END IF;

    INSERT INTO qvm_new_apps.end_customers
      (customer_kind, name, insurance_company_id, tax_number, contact_person, phone, email,
       requires_customer_approval, requires_workshop_approval, created_by, updated_by)
    VALUES (v_kind,
            CASE WHEN v_kind = 'insurance' THEN NULL ELSE NULLIF(btrim(COALESCE(p_name, '')), '') END,
            CASE WHEN v_kind = 'insurance' THEN p_insurance_company_id END,
            CASE WHEN v_kind = 'company' THEN NULLIF(btrim(COALESCE(p_tax_number, '')), '') END,
            NULLIF(btrim(COALESCE(p_contact_person, '')), ''),
            NULLIF(btrim(COALESCE(p_phone, '')), ''),
            NULLIF(lower(btrim(COALESCE(p_email, ''))), ''),
            COALESCE(p_requires_customer_approval, true), COALESCE(p_requires_workshop_approval, true),
            v_uid, v_uid)
    RETURNING end_customer_id INTO v_id;

    IF p_owner_kind IN ('workshop', 'vendor') THEN
      INSERT INTO qvm_new_apps.end_customer_owners (end_customer_id, workshop_id, vendor_id, created_by)
      VALUES (v_id,
              CASE WHEN p_owner_kind = 'workshop' THEN p_owner_id END,
              CASE WHEN p_owner_kind = 'vendor' THEN p_owner_id::integer END,
              v_uid);
    END IF;
  ELSE
    IF NOT qvm_new_apps.can_admin_end_customer(v_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
    END IF;
    -- The kind is not editable. Changing it would strand a tax number on an individual or leave an
    -- insurance customer pointing at a list row it no longer is.
    UPDATE qvm_new_apps.end_customers
       SET name = CASE WHEN customer_kind = 'insurance' THEN NULL
                       ELSE COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), name) END,
           insurance_company_id = CASE WHEN customer_kind = 'insurance'
                                       THEN COALESCE(p_insurance_company_id, insurance_company_id) END,
           tax_number = CASE WHEN customer_kind = 'company'
                             THEN NULLIF(btrim(COALESCE(p_tax_number, '')), '') END,
           contact_person = NULLIF(btrim(COALESCE(p_contact_person, '')), ''),
           phone = NULLIF(btrim(COALESCE(p_phone, '')), ''),
           email = NULLIF(lower(btrim(COALESCE(p_email, ''))), ''),
           requires_customer_approval = COALESCE(p_requires_customer_approval, requires_customer_approval),
           requires_workshop_approval = COALESCE(p_requires_workshop_approval, requires_workshop_approval),
           updated_by = v_uid, updated_at = now()
     WHERE end_customer_id = v_id;
  END IF;

  -- English name, register kind and number, and a tax number for any kind but insurance.
  PERFORM qvm_new_apps._apply_end_customer_details(v_id, p_details);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'end_customer_id', v_id,
    'customer_code', (SELECT customer_code FROM qvm_new_apps.end_customers WHERE end_customer_id = v_id)));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean, jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_upsert_end_customer(
  p_end_customer_id bigint DEFAULT NULL, p_customer_kind text DEFAULT NULL, p_name text DEFAULT NULL, p_insurance_company_id bigint DEFAULT NULL,
  p_tax_number text DEFAULT NULL, p_contact_person text DEFAULT NULL, p_phone text DEFAULT NULL, p_email text DEFAULT NULL,
  p_owner_kind text DEFAULT NULL, p_owner_id bigint DEFAULT NULL, p_requires_customer_approval boolean DEFAULT NULL, p_requires_workshop_approval boolean DEFAULT NULL,
  p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_end_customer(p_end_customer_id, p_customer_kind, p_name, p_insurance_company_id, p_tax_number, p_contact_person, p_phone, p_email,
                                                p_owner_kind, p_owner_id, p_requires_customer_approval, p_requires_workshop_approval, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_end_customer_branch(p_end_customer_id bigint, p_branch_id bigint DEFAULT NULL::bigint, p_names jsonb DEFAULT NULL::jsonb, p_city_id integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint := p_branch_id;
  v_default_name text;
BEGIN
  IF NOT qvm_new_apps.can_admin_end_customer(p_end_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.end_customer_branches (end_customer_id, branch_name, city_id, created_by, updated_by)
    VALUES (p_end_customer_id, v_default_name, p_city_id, v_uid, v_uid)
    RETURNING end_customer_branch_id INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_branches
                    WHERE end_customer_branch_id = v_id AND end_customer_id = p_end_customer_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'That branch does not belong to this customer');
    END IF;
    UPDATE qvm_new_apps.end_customer_branches
       SET branch_name = COALESCE(v_default_name, branch_name),
           city_id = COALESCE(p_city_id, city_id),
           is_active = COALESCE(p_is_active, is_active),
           updated_by = v_uid, updated_at = now()
     WHERE end_customer_branch_id = v_id;
  END IF;

  PERFORM qvm_new_apps._apply_end_customer_branch_details(v_id, p_details);

  INSERT INTO qvm_new_apps.end_customer_branches_descriptions
    (end_customer_branch_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (end_customer_branch_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('end_customer_branch_id', v_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_end_customer_branch(bigint, bigint, jsonb, integer, boolean, jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_upsert_end_customer_branch(
  p_end_customer_id bigint, p_branch_id bigint DEFAULT NULL, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL, p_is_active boolean DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_end_customer_branch(p_end_customer_id, p_branch_id, p_names, p_city_id, p_is_active, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_upsert_end_customer_branch(bigint, bigint, jsonb, integer, boolean, jsonb) TO authenticated;

-- A customer document: the uploaded file, given its type and expiry.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_end_customer_document(
  p_end_customer_id bigint, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  IF NOT qvm_new_apps.can_admin_end_customer(p_end_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;
  IF p_doc_type IS NULL OR p_doc_type NOT IN ('cr', 'vat', 'national_address', 'iban', 'other') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown document type');
  END IF;
  SELECT f.id INTO v_id FROM qvm_new_apps.files f
   WHERE f.module_type = 'end_customers' AND f.module_id = p_end_customer_id
     AND (p_file_id IS NULL OR f.id = p_file_id) AND (p_file_id IS NOT NULL OR f.field_id = p_doc_type)
   ORDER BY f.created_at DESC LIMIT 1;
  IF v_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'The uploaded file was not found on this customer'); END IF;
  UPDATE qvm_new_apps.files SET doc_type = p_doc_type, expires_on = p_expires_on, doc_number = NULLIF(btrim(COALESCE(p_doc_number, '')), '') WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', v_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_end_customer_document(bigint, text, bigint, date, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_end_customer_document(p_end_customer_id bigint, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_set_end_customer_document(p_end_customer_id, p_doc_type, p_file_id, p_expires_on, p_doc_number); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_end_customer_document(bigint, text, bigint, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_delete_end_customer_document(p_file_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_owner bigint;
BEGIN
  SELECT f.module_id INTO v_owner FROM qvm_new_apps.files f WHERE f.id = p_file_id AND f.module_type = 'end_customers';
  IF v_owner IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Document not found'); END IF;
  IF NOT qvm_new_apps.can_admin_end_customer(v_owner) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;
  DELETE FROM qvm_new_apps.files WHERE id = p_file_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', p_file_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_delete_end_customer_document(bigint) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_delete_end_customer_document(p_file_id bigint) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_delete_end_customer_document(p_file_id); $$;
GRANT EXECUTE ON FUNCTION public.admin_delete_end_customer_document(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_end_customer_address_type(p_address_id bigint, p_address_type text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_branch bigint;
BEGIN
  SELECT a.end_customer_branch_id INTO v_branch FROM qvm_new_apps.end_customer_addresses a WHERE a.address_id = p_address_id;
  IF v_branch IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Address not found'); END IF;
  IF NOT qvm_new_apps.can_admin_end_customer_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  IF p_address_type IS NOT NULL AND p_address_type NOT IN ('warehouse', 'showroom', 'office', 'pickup') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown address type');
  END IF;
  UPDATE qvm_new_apps.end_customer_addresses SET address_type = p_address_type WHERE address_id = p_address_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_end_customer_address_type(bigint, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_end_customer_address_type(p_address_id bigint, p_address_type text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_set_end_customer_address_type(p_address_id, p_address_type); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_end_customer_address_type(bigint, text) TO authenticated;

-- The insurance registry carries the official numbers an insurance customer inherits.
DROP FUNCTION IF EXISTS qvm_new_apps.list_insurance_companies();
CREATE OR REPLACE FUNCTION qvm_new_apps.list_insurance_companies()
 RETURNS TABLE(id bigint, client_id integer, client_name text, name text, name_en text, tax_number text, cr_number text, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  RETURN QUERY
  SELECT ic.id, ic.client_id, ld.list_data AS client_name, ic.name, ic.name_en, ic.tax_number, ic.cr_number, ic.created_at, ic.updated_at
  FROM qvm_new_apps.insurance_companies ic
  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ic.client_id
  ORDER BY ic.name ASC;
END;
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_insurance_companies() TO authenticated;

DROP FUNCTION IF EXISTS qvm_new_apps.create_insurance_company(text);
CREATE OR REPLACE FUNCTION qvm_new_apps.create_insurance_company(p_name text, p_name_en text DEFAULT NULL, p_tax_number text DEFAULT NULL, p_cr_number text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_id bigint; v_client_id integer;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RETURN jsonb_build_object('status', 'error', 'message', 'Name is required'); END IF;
  SELECT user_company INTO v_client_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  IF v_client_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client — contact an administrator');
  END IF;
  INSERT INTO qvm_new_apps.insurance_companies (client_id, name, name_en, tax_number, cr_number)
  VALUES (v_client_id, btrim(p_name), NULLIF(btrim(COALESCE(p_name_en, '')), ''), NULLIF(btrim(COALESCE(p_tax_number, '')), ''), NULLIF(btrim(COALESCE(p_cr_number, '')), ''))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status', 'success', 'id', v_id);
END;
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_insurance_company(text, text, text, text) TO authenticated;

DROP FUNCTION IF EXISTS qvm_new_apps.update_insurance_company(bigint, text);
CREATE OR REPLACE FUNCTION qvm_new_apps.update_insurance_company(p_id bigint, p_name text, p_name_en text DEFAULT NULL, p_tax_number text DEFAULT NULL, p_cr_number text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RETURN jsonb_build_object('status', 'error', 'message', 'Name is required'); END IF;
  UPDATE qvm_new_apps.insurance_companies
     SET name = btrim(p_name), name_en = NULLIF(btrim(COALESCE(p_name_en, '')), ''), tax_number = NULLIF(btrim(COALESCE(p_tax_number, '')), ''),
         cr_number = NULLIF(btrim(COALESCE(p_cr_number, '')), ''), updated_at = now()
   WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'error', 'message', 'Insurance company not found'); END IF;
  RETURN jsonb_build_object('status', 'success');
END;
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.update_insurance_company(bigint, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_customer_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH customer_json AS (
    SELECT c.end_customer_id,
           jsonb_build_object(
             'end_customer_id', c.end_customer_id,
             'display_name', c.name,
             'customer_kind', c.customer_kind,
             'customer_code', c.customer_code,
             'insurance_company_id', c.insurance_company_id,
             'tax_number', c.tax_number,
             -- Identity, as the customer form collects it.
             'name_en', ec.name_en,
             'cr_kind', ec.cr_kind,
             'cr_number', ec.cr_number,
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'end_customers' AND f.module_id = c.end_customer_id), '[]'::jsonb),
             'contact_person', c.contact_person,
             'phone', c.phone,
             'email', c.email,
             'is_active', c.is_active,
             'requires_customer_approval', c.requires_customer_approval,
             'requires_workshop_approval', c.requires_workshop_approval,
             'branch_count', c.branch_count,
             'user_count', c.user_count,
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'end_customer_branch_id', b.end_customer_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'branch_code', eb.branch_code,
                        'brand_ids', COALESCE(to_jsonb(eb.brand_ids), '[]'::jsonb),
                        'part_category_ids', COALESCE(to_jsonb(eb.part_category_ids), '[]'::jsonb),
                        'banks', COALESCE(eb.banks, '[]'::jsonb),
                        'account_type', eb.account_type,
                        'credit_limit', eb.credit_limit,
                        'credit_term_days', eb.credit_term_days,
                        'hours_mode', eb.hours_mode,
                        'working_hours', COALESCE(eb.working_hours, '[]'::jsonb),
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.end_customer_branches_descriptions bd
                                            WHERE bd.end_customer_branch_id = b.end_customer_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_end_customer_branches b
                 JOIN qvm_new_apps.end_customer_branches eb ON eb.end_customer_branch_id = b.end_customer_branch_id
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.end_customer_id = c.end_customer_id), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.v_end_customers c
    JOIN qvm_new_apps.end_customers ec ON ec.end_customer_id = c.end_customer_id
  ),
  -- Every workshop and vendor the caller can administer, as one list: on this screen they are the
  -- same kind of thing — somebody who has customers.
  owners AS (
    SELECT 'workshop'::text AS owner_kind, w.workshop_id::bigint AS owner_id, vw.name,
           w.workshop_code AS code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.workshop_companies x
             WHERE x.workshop_id = w.workshop_id) AS company_ids
      FROM qvm_new_apps.client_workshops w
      JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
     WHERE qvm_new_apps.can_admin_workshop(w.workshop_id)
    UNION ALL
    SELECT 'vendor', v.vendor_id::bigint, vv.name, v.vendor_code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.vendor_companies x
             WHERE x.vendor_id = v.vendor_id)
      FROM qvm_new_apps.vendors v
      JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
     WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    'insurance_companies', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', ic.id, 'name', ic.name,
                                                       'name_en', ic.name_en, 'tax_number', ic.tax_number, 'cr_number', ic.cr_number)
                                                     ORDER BY ic.name)
                                       FROM qvm_new_apps.insurance_companies ic), '[]'::jsonb),
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                  FROM customer_json cj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_owners o
                                    WHERE o.end_customer_id = cj.end_customer_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'owners', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                     'owner_kind', o.owner_kind,
                     'owner_id', o.owner_id,
                     'display_name', o.name,
                     'code', o.code,
                     'customers', COALESCE((
                       SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                         FROM customer_json cj
                         JOIN qvm_new_apps.end_customer_owners eo
                           ON eo.end_customer_id = cj.end_customer_id
                          AND ((o.owner_kind = 'workshop' AND eo.workshop_id = o.owner_id)
                            OR (o.owner_kind = 'vendor'   AND eo.vendor_id = o.owner_id))), '[]'::jsonb))
                   ORDER BY o.owner_kind, o.name)
              FROM owners o
             WHERE o.company_ids @> to_jsonb(c.company_id)), '[]'::jsonb)
        ) AS co
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
      ) s), '[]'::jsonb)
  )) INTO v_res;

  RETURN v_res;
END $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 48 $$;
