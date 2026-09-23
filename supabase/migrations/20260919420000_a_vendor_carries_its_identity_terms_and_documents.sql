-- A vendor carries its identity, terms and documents; its branches their code, brands, banks and hours.
--
-- The add-vendor design mirrors the workshop one. The Vendors tree's create and edit forms now
-- collect the same fields, saved on the columns the vendor tables already have where they exist
-- (type, tax, register, receives quotations, brands, categories, banks) and on new ones where not.
ALTER TABLE qvm_new_apps.vendors ADD COLUMN IF NOT EXISTS cr_kind text;
ALTER TABLE qvm_new_apps.vendors DROP CONSTRAINT IF EXISTS vendors_cr_kind_check;
ALTER TABLE qvm_new_apps.vendors ADD CONSTRAINT vendors_cr_kind_check CHECK (cr_kind IS NULL OR cr_kind IN ('cr', 'unified'));
ALTER TABLE qvm_new_apps.vendor_branches
  ADD COLUMN IF NOT EXISTS branch_code text,
  ADD COLUMN IF NOT EXISTS account_type text,
  ADD COLUMN IF NOT EXISTS credit_limit numeric,
  ADD COLUMN IF NOT EXISTS credit_term_days integer,
  ADD COLUMN IF NOT EXISTS hours_mode text,
  ADD COLUMN IF NOT EXISTS working_hours jsonb;
ALTER TABLE qvm_new_apps.vendor_branches DROP CONSTRAINT IF EXISTS vendor_branches_account_type_check;
ALTER TABLE qvm_new_apps.vendor_branches ADD CONSTRAINT vendor_branches_account_type_check CHECK (account_type IS NULL OR account_type IN ('credit', 'cash'));
ALTER TABLE qvm_new_apps.vendor_branches DROP CONSTRAINT IF EXISTS vendor_branches_hours_mode_check;
ALTER TABLE qvm_new_apps.vendor_branches ADD CONSTRAINT vendor_branches_hours_mode_check CHECK (hours_mode IS NULL OR hours_mode IN ('247', 'schedule'));
ALTER TABLE qvm_new_apps.vendor_addresses ADD COLUMN IF NOT EXISTS address_type text;
ALTER TABLE qvm_new_apps.vendor_addresses DROP CONSTRAINT IF EXISTS vendor_addresses_address_type_check;
ALTER TABLE qvm_new_apps.vendor_addresses ADD CONSTRAINT vendor_addresses_address_type_check CHECK (address_type IS NULL OR address_type IN ('warehouse', 'showroom', 'office', 'pickup'));

CREATE OR REPLACE FUNCTION qvm_new_apps._apply_vendor_details(p_vendor_id integer, p jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_type_id integer; v_type_name text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'cr_kind' AND NULLIF(btrim(p->>'cr_kind'), '') IS NOT NULL AND (p->>'cr_kind') NOT IN ('cr', 'unified') THEN
    RAISE EXCEPTION 'Unknown registration kind';
  END IF;
  IF p ? 'vendor_type_id' THEN
    v_type_id := NULLIF(regexp_replace(COALESCE(p->>'vendor_type_id', ''), '[^0-9]', '', 'g'), '')::int;
    SELECT ld.list_data INTO v_type_name FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = v_type_id;
    IF v_type_id IS NOT NULL AND v_type_name IS NULL THEN RAISE EXCEPTION 'Unknown vendor type'; END IF;
  END IF;
  UPDATE qvm_new_apps.vendors v
     SET vendor_type_id = CASE WHEN p ? 'vendor_type_id' THEN v_type_id ELSE v.vendor_type_id END,
         vendor_type    = CASE WHEN p ? 'vendor_type_id' THEN v_type_name ELSE v.vendor_type END,
         tax_number     = CASE WHEN p ? 'vat_number' THEN NULLIF(btrim(p->>'vat_number'), '') ELSE v.tax_number END,
         cr_kind        = CASE WHEN p ? 'cr_kind' THEN NULLIF(btrim(p->>'cr_kind'), '') ELSE v.cr_kind END,
         commercial_registeration_number = CASE WHEN p ? 'cr_number' THEN NULLIF(btrim(p->>'cr_number'), '') ELSE v.commercial_registeration_number END,
         receives_quotations = CASE WHEN p ? 'receives_requests' THEN COALESCE((p->>'receives_requests')::boolean, v.receives_quotations) ELSE v.receives_quotations END,
         updated_at = now()
   WHERE v.vendor_id = p_vendor_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_vendor_details(integer, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION qvm_new_apps._apply_vendor_branch_details(p_vendor_branch_id bigint, p jsonb)
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
  UPDATE qvm_new_apps.vendor_branches b
     SET branch_code   = CASE WHEN p ? 'branch_code' THEN NULLIF(btrim(p->>'branch_code'), '') ELSE b.branch_code END,
         brands        = CASE WHEN p ? 'brand_ids' THEN COALESCE(p->'brand_ids', '[]'::jsonb) ELSE b.brands END,
         categories    = CASE WHEN p ? 'part_category_ids' THEN COALESCE(p->'part_category_ids', '[]'::jsonb) ELSE b.categories END,
         -- Stored with the keys the vendor portal reads (bank_name, bank_account_name, bank_iban)
         -- and the English name beside them.
         banks         = CASE WHEN p ? 'banks' THEN COALESCE((SELECT jsonb_agg(jsonb_build_object(
                             'bank_name', COALESCE(x->>'bank_name', ''),
                             'bank_account_name', COALESCE(x->>'account_name_ar', x->>'bank_account_name', ''),
                             'bank_account_name_en', COALESCE(x->>'account_name_en', ''),
                             'bank_iban', COALESCE(x->>'iban', x->>'bank_iban', ''),
                             'bank_and_cr_files', COALESCE(x->'bank_and_cr_files', '[]'::jsonb)))
                           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'banks') = 'array' THEN p->'banks' ELSE '[]'::jsonb END) x), '[]'::jsonb)
                         ELSE b.banks END,
         account_type  = CASE WHEN p ? 'account_type' THEN NULLIF(btrim(p->>'account_type'), '') ELSE b.account_type END,
         payment_method = CASE WHEN p ? 'account_type' THEN CASE p->>'account_type' WHEN 'cash' THEN 'Cash' WHEN 'credit' THEN 'Credit' ELSE b.payment_method END ELSE b.payment_method END,
         credit_limit  = CASE WHEN p ? 'credit_limit' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_limit', ''), '[^0-9.]', '', 'g'), '')::numeric ELSE b.credit_limit END,
         credit_term_days = CASE WHEN p ? 'credit_term_days' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_term_days', ''), '[^0-9]', '', 'g'), '')::int ELSE b.credit_term_days END,
         hours_mode    = CASE WHEN p ? 'hours_mode' THEN NULLIF(btrim(p->>'hours_mode'), '') ELSE b.hours_mode END,
         working_hours = CASE WHEN p ? 'working_hours' THEN COALESCE(p->'working_hours', '[]'::jsonb) ELSE b.working_hours END,
         updated_at = now()
   WHERE b.vendor_branch_id = p_vendor_branch_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_vendor_branch_details(bigint, jsonb) FROM PUBLIC;

-- Trailing defaults make new overloads; the old shapes go so a call stays unambiguous.
DROP FUNCTION IF EXISTS public.admin_upsert_vendor(integer, jsonb, integer, text, integer[]);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_vendor(integer, jsonb, integer, text, integer[]);
DROP FUNCTION IF EXISTS public.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_vendor(p_vendor_id integer DEFAULT NULL::integer, p_names jsonb DEFAULT NULL::jsonb, p_city_id integer DEFAULT NULL::integer, p_email text DEFAULT NULL::text, p_company_ids integer[] DEFAULT NULL::integer[], p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id integer := p_vendor_id;
  v_default_name text;
  v_ids integer[] := COALESCE(p_company_ids, ARRAY[]::integer[]);
BEGIN
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF v_id IS NULL THEN
    -- Creating one is a Qparts act, or a Company Admin's for their own company: a vendor with no
    -- company would otherwise be created by someone who then cannot see it.
    IF NOT (qvm_new_apps.is_qparts_admin(v_uid)
            OR (qvm_new_apps.is_company_admin(v_uid)
                AND array_length(v_ids, 1) IS NOT NULL
                AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c)) FROM unnest(v_ids) c), false))) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
    END IF;

    INSERT INTO qvm_new_apps.vendors (vendor_name, email, city_id)
    VALUES (v_default_name, NULLIF(btrim(COALESCE(p_email, '')), ''), p_city_id)
    RETURNING vendor_id INTO v_id;
  ELSE
    IF NOT qvm_new_apps.can_admin_vendor(v_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
    END IF;
    UPDATE qvm_new_apps.vendors
       SET vendor_name = COALESCE(v_default_name, vendor_name),
           email = COALESCE(NULLIF(btrim(COALESCE(p_email, '')), ''), email),
           city_id = COALESCE(p_city_id, city_id)
     WHERE vendor_id = v_id;
  END IF;

  -- Type, registration numbers and whether it takes requests, when the form carried them.
  PERFORM qvm_new_apps._apply_vendor_details(v_id, p_details);

  INSERT INTO qvm_new_apps.vendors_descriptions (vendor_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (vendor_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  DELETE FROM qvm_new_apps.vendors_descriptions d
   WHERE d.vendor_id = v_id
     AND d.language_id <> qvm_new_apps.default_language_id()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = d.language_id
                        AND btrim(COALESCE(n->>'name', '')) <> '');

  IF p_vendor_id IS NULL AND array_length(v_ids, 1) IS NOT NULL THEN
    INSERT INTO qvm_new_apps.vendor_companies (vendor_id, company_id, created_by)
    SELECT v_id, c, v_uid FROM unnest(v_ids) c
    ON CONFLICT (vendor_id, company_id) DO NOTHING;
    UPDATE qvm_new_apps.vendor_companies SET is_primary = true
     WHERE vendor_id = v_id AND company_id = v_ids[1];
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('vendor_id', v_id));
END $function;

GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_vendor(integer, jsonb, integer, text, integer[], jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_upsert_vendor(
  p_vendor_id integer DEFAULT NULL, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL, p_email text DEFAULT NULL, p_company_ids integer[] DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_vendor(p_vendor_id, p_names, p_city_id, p_email, p_company_ids, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_upsert_vendor(integer, jsonb, integer, text, integer[], jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_vendor_branch(p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL::bigint, p_names jsonb DEFAULT NULL::jsonb, p_city_id integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint := p_vendor_branch_id;
  v_default_name text;
  v_city text;
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor(p_vendor_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);
  SELECT c.name INTO v_city FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;

  IF v_id IS NULL THEN
    -- branch_name and city are NOT NULL on this table and read by the vendor portal, so both are
    -- kept filled from the localized name and the chosen city rather than left behind.
    INSERT INTO qvm_new_apps.vendor_branches (vendor_id, branch_name, city, city_id)
    VALUES (p_vendor_id, v_default_name, COALESCE(v_city, ''), p_city_id)
    RETURNING vendor_branch_id INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branches
                    WHERE vendor_branch_id = v_id AND vendor_id = p_vendor_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'That branch does not belong to this vendor');
    END IF;
    UPDATE qvm_new_apps.vendor_branches
       SET branch_name = COALESCE(v_default_name, branch_name),
           city = COALESCE(v_city, city),
           city_id = COALESCE(p_city_id, city_id),
           is_active = COALESCE(p_is_active, is_active),
           updated_at = now()
     WHERE vendor_branch_id = v_id;
  END IF;

  PERFORM qvm_new_apps._apply_vendor_branch_details(v_id, p_details);

  INSERT INTO qvm_new_apps.vendor_branches_descriptions (vendor_branch_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (vendor_branch_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('vendor_branch_id', v_id));
END $function;

GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean, jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_upsert_vendor_branch(
  p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL, p_is_active boolean DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_vendor_branch(p_vendor_id, p_vendor_branch_id, p_names, p_city_id, p_is_active, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean, jsonb) TO authenticated;

-- A vendor document: the uploaded file, given its type and expiry.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_vendor_document(
  p_vendor_id integer, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor(p_vendor_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;
  IF p_doc_type IS NULL OR p_doc_type NOT IN ('cr', 'vat', 'national_address', 'iban', 'other') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown document type');
  END IF;
  SELECT f.id INTO v_id FROM qvm_new_apps.files f
   WHERE f.module_type = 'vendors' AND f.module_id = p_vendor_id
     AND (p_file_id IS NULL OR f.id = p_file_id) AND (p_file_id IS NOT NULL OR f.field_id = p_doc_type)
   ORDER BY f.created_at DESC LIMIT 1;
  IF v_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'The uploaded file was not found on this vendor'); END IF;
  UPDATE qvm_new_apps.files SET doc_type = p_doc_type, expires_on = p_expires_on, doc_number = NULLIF(btrim(COALESCE(p_doc_number, '')), '') WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', v_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_vendor_document(integer, text, bigint, date, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_vendor_document(p_vendor_id integer, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_set_vendor_document(p_vendor_id, p_doc_type, p_file_id, p_expires_on, p_doc_number); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_document(integer, text, bigint, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_delete_vendor_document(p_file_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_vendor integer;
BEGIN
  SELECT f.module_id INTO v_vendor FROM qvm_new_apps.files f WHERE f.id = p_file_id AND f.module_type = 'vendors';
  IF v_vendor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Document not found'); END IF;
  IF NOT qvm_new_apps.can_admin_vendor(v_vendor) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;
  DELETE FROM qvm_new_apps.files WHERE id = p_file_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', p_file_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_delete_vendor_document(bigint) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_delete_vendor_document(p_file_id bigint) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_delete_vendor_document(p_file_id); $$;
GRANT EXECUTE ON FUNCTION public.admin_delete_vendor_document(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_vendor_address_type(p_address_id bigint, p_address_type text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_branch bigint;
BEGIN
  SELECT a.vendor_branch_id INTO v_branch FROM qvm_new_apps.vendor_addresses a WHERE a.address_id = p_address_id;
  IF v_branch IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Address not found'); END IF;
  IF NOT qvm_new_apps.can_admin_vendor_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  IF p_address_type IS NOT NULL AND p_address_type NOT IN ('warehouse', 'showroom', 'office', 'pickup') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown address type');
  END IF;
  UPDATE qvm_new_apps.vendor_addresses SET address_type = p_address_type WHERE address_id = p_address_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_vendor_address_type(bigint, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_vendor_address_type(p_address_id bigint, p_address_type text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_set_vendor_address_type(p_address_id, p_address_type); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_address_type(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_vendor_tree()
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

  WITH vendor_json AS (
    SELECT v.vendor_id,
           jsonb_build_object(
             'vendor_id', v.vendor_id,
             'display_name', COALESCE(vv.name, v.vendor_name),
             'vendor_code', v.vendor_code,
             'vendor_type', v.vendor_type,
             'email', v.email,
             -- Identity and terms, as the vendor form collects them.
             'vendor_type_id', v.vendor_type_id,
             'tax_number', v.tax_number,
             'cr_kind', v.cr_kind,
             'cr_number', v.commercial_registeration_number,
             'receives_quotations', COALESCE(v.receives_quotations, true),
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'vendors' AND f.module_id = v.vendor_id), '[]'::jsonb),
             'city', vc.name,
             'city_id', v.city_id,
             'branch_count', vv.branch_count,
             'company_ids', COALESCE((SELECT jsonb_agg(x.company_id ORDER BY x.company_id)
                                        FROM qvm_new_apps.vendor_companies x
                                       WHERE x.vendor_id = v.vendor_id), '[]'::jsonb),
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.vendors_descriptions d
                                 WHERE d.vendor_id = v.vendor_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'vendor_branch_id', b.vendor_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'branch_code', vb.branch_code,
                        'brand_ids', COALESCE(vb.brands, '[]'::jsonb),
                        'part_category_ids', COALESCE(vb.categories, '[]'::jsonb),
                        -- The bank rows in the shape the shared form uses; the vendor portal's keys stay on the row.
                        'banks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                     'bank_name', COALESCE(x->>'bank_name', ''),
                                     'account_name_ar', COALESCE(x->>'bank_account_name', ''),
                                     'account_name_en', COALESCE(x->>'bank_account_name_en', ''),
                                     'iban', COALESCE(x->>'bank_iban', '')))
                                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(vb.banks) = 'array' THEN vb.banks ELSE '[]'::jsonb END) x), '[]'::jsonb),
                        'account_type', vb.account_type,
                        'credit_limit', vb.credit_limit,
                        'credit_term_days', vb.credit_term_days,
                        'hours_mode', vb.hours_mode,
                        'working_hours', COALESCE(vb.working_hours, '[]'::jsonb),
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.vendor_branches_descriptions bd
                                            WHERE bd.vendor_branch_id = b.vendor_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_vendor_branches b
                 JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = b.vendor_branch_id
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.vendor_id = v.vendor_id), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.vendors v
    JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
    LEFT JOIN qvm_new_apps.v_cities vc ON vc.city_id = v.city_id
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    -- A vendor nobody has linked belongs to no company, so it is nobody's but Qparts'.
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                  FROM vendor_json vj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies x
                                    WHERE x.vendor_id = vj.vendor_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY s.vendor_count DESC, s.created_at DESC NULLS LAST, co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'created_at', c.created_at,
          'vendor_count', (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id),
          'vendors', COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                                 FROM vendor_json vj
                                 JOIN qvm_new_apps.vendor_companies x
                                   ON x.vendor_id = vj.vendor_id AND x.company_id = c.company_id), '[]'::jsonb)
        ) AS co,
        c.created_at,
        (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id) AS vendor_count
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
      ) s), '[]'::jsonb)
  )) INTO v_res;

  RETURN v_res;
END $function;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 46 $$;
