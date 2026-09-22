-- A workshop carries its identity, its terms and its documents.
--
-- The add-workshop design asks for the workshop's type, tax number, commercial register (or unified
-- number), first account terms and the five registration documents with their expiry. The New and
-- Edit workshop modals on Companies & Workshops now collect them; the tree returns them.
ALTER TABLE qvm_new_apps.client_workshops
  ADD COLUMN IF NOT EXISTS workshop_type text,
  ADD COLUMN IF NOT EXISTS vat_number text,
  ADD COLUMN IF NOT EXISTS cr_kind text,
  ADD COLUMN IF NOT EXISTS cr_number text,
  ADD COLUMN IF NOT EXISTS account_type text,
  ADD COLUMN IF NOT EXISTS credit_limit numeric,
  ADD COLUMN IF NOT EXISTS credit_term_days integer,
  ADD COLUMN IF NOT EXISTS receives_requests boolean NOT NULL DEFAULT true;
ALTER TABLE qvm_new_apps.client_workshops DROP CONSTRAINT IF EXISTS client_workshops_workshop_type_check;
ALTER TABLE qvm_new_apps.client_workshops ADD CONSTRAINT client_workshops_workshop_type_check
  CHECK (workshop_type IS NULL OR workshop_type IN ('general', 'body_paint', 'electrical', 'mechanical', 'quick_service'));
ALTER TABLE qvm_new_apps.client_workshops DROP CONSTRAINT IF EXISTS client_workshops_cr_kind_check;
ALTER TABLE qvm_new_apps.client_workshops ADD CONSTRAINT client_workshops_cr_kind_check
  CHECK (cr_kind IS NULL OR cr_kind IN ('cr', 'unified'));
ALTER TABLE qvm_new_apps.client_workshops DROP CONSTRAINT IF EXISTS client_workshops_account_type_check;
ALTER TABLE qvm_new_apps.client_workshops ADD CONSTRAINT client_workshops_account_type_check
  CHECK (account_type IS NULL OR account_type IN ('credit', 'cash'));

-- Applies whichever detail keys the form sent; keys absent from the object are left as they are,
-- keys present with null clear the field.
CREATE OR REPLACE FUNCTION qvm_new_apps._apply_workshop_details(p_workshop_id bigint, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'workshop_type' AND NULLIF(btrim(p->>'workshop_type'), '') IS NOT NULL
     AND (p->>'workshop_type') NOT IN ('general', 'body_paint', 'electrical', 'mechanical', 'quick_service') THEN
    RAISE EXCEPTION 'Unknown workshop type';
  END IF;
  IF p ? 'cr_kind' AND NULLIF(btrim(p->>'cr_kind'), '') IS NOT NULL AND (p->>'cr_kind') NOT IN ('cr', 'unified') THEN
    RAISE EXCEPTION 'Unknown registration kind';
  END IF;
  IF p ? 'account_type' AND NULLIF(btrim(p->>'account_type'), '') IS NOT NULL AND (p->>'account_type') NOT IN ('credit', 'cash') THEN
    RAISE EXCEPTION 'Unknown account type';
  END IF;
  UPDATE qvm_new_apps.client_workshops w
     SET workshop_type    = CASE WHEN p ? 'workshop_type'    THEN NULLIF(btrim(p->>'workshop_type'), '') ELSE w.workshop_type END,
         vat_number       = CASE WHEN p ? 'vat_number'       THEN NULLIF(btrim(p->>'vat_number'), '')    ELSE w.vat_number END,
         cr_kind          = CASE WHEN p ? 'cr_kind'          THEN NULLIF(btrim(p->>'cr_kind'), '')       ELSE w.cr_kind END,
         cr_number        = CASE WHEN p ? 'cr_number'        THEN NULLIF(btrim(p->>'cr_number'), '')     ELSE w.cr_number END,
         account_type     = CASE WHEN p ? 'account_type'     THEN NULLIF(btrim(p->>'account_type'), '')  ELSE w.account_type END,
         credit_limit     = CASE WHEN p ? 'credit_limit'     THEN NULLIF(regexp_replace(COALESCE(p->>'credit_limit', ''), '[^0-9.]', '', 'g'), '')::numeric ELSE w.credit_limit END,
         credit_term_days = CASE WHEN p ? 'credit_term_days' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_term_days', ''), '[^0-9]', '', 'g'), '')::int ELSE w.credit_term_days END,
         receives_requests = CASE WHEN p ? 'receives_requests' THEN COALESCE((p->>'receives_requests')::boolean, w.receives_requests) ELSE w.receives_requests END,
         updated_by = auth.uid(), updated_at = now()
   WHERE w.workshop_id = p_workshop_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_workshop_details(bigint, jsonb) FROM PUBLIC;

-- Trailing defaults make new overloads; the old shapes go so a call stays unambiguous.
DROP FUNCTION IF EXISTS public.admin_create_workshop(integer[], jsonb, jsonb, integer);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_create_workshop(integer[], jsonb, jsonb, integer);
DROP FUNCTION IF EXISTS public.admin_update_workshop(bigint, jsonb, integer, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_update_workshop(bigint, jsonb, integer, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(p_company_ids integer[], p_names jsonb, p_branches jsonb, p_city_id integer DEFAULT NULL::integer, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ws bigint; v_branch integer; b jsonb;
  v_ids integer[] := ARRAY[]::integer[];
  v_companies integer[] := COALESCE(p_company_ids, ARRAY[]::integer[]);
  v_primary integer := v_companies[1];
  v_city_name text; v_lat double precision; v_lng double precision;
  v_bcity integer; v_bname text; v_blat double precision; v_blng double precision;
  v_ready jsonb := '[]'::jsonb;
BEGIN
  -- A Company Admin may open a workshop for a company they hold; a Qparts Admin for any. A
  -- workshop with no company at all is a Qparts staging area, so it stays theirs.
  IF NOT COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c)) FROM unnest(v_companies) c),
                  qvm_new_apps.is_qparts_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_companies) c
              WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = c)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'One of the companies does not exist');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  IF p_branches IS NULL OR jsonb_typeof(p_branches) <> 'array' OR jsonb_array_length(p_branches) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'A workshop must be created with at least one branch');
  END IF;
  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    PERFORM qvm_new_apps.assert_names_valid(b->'names');
  END LOOP;

  IF p_city_id IS NOT NULL THEN
    SELECT c.name, c.location_lat, c.location_lng INTO v_city_name, v_lat, v_lng
    FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
    IF v_city_name IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'City not found');
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.client_workshops (company_id, city_id, city, location_lat, location_lng, created_by, updated_by)
  VALUES (v_primary, p_city_id, v_city_name, v_lat, v_lng, v_uid, v_uid)
  RETURNING workshop_id INTO v_ws;

  INSERT INTO qvm_new_apps.workshop_companies (workshop_id, company_id, is_primary, created_by)
  SELECT v_ws, c, c = v_primary, v_uid FROM unnest(v_companies) c;

  -- Type, registration numbers and commercial terms, when the form carried them.
  PERFORM qvm_new_apps._apply_workshop_details(v_ws, p_details);

  INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, language_id, name, created_by, updated_by)
  SELECT v_ws, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> '';

  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    v_bcity := COALESCE((b->>'city_id')::int, p_city_id);
    SELECT c.name, c.location_lat, c.location_lng INTO v_bname, v_blat, v_blng
    FROM qvm_new_apps.v_cities c WHERE c.city_id = v_bcity;

    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city_id, city, location_lat, location_lng, is_bulk_client)
    VALUES (v_primary, v_ws,
            (SELECT btrim(n->>'name') FROM jsonb_array_elements(b->'names') n
              WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1),
            v_bcity, v_bname, v_blat, v_blng,
            COALESCE((b->>'is_bulk_client')::boolean, false))
    RETURNING customer_id INTO v_branch;

    INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
    SELECT v_branch, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
    FROM jsonb_array_elements(b->'names') n
    WHERE btrim(COALESCE(n->>'name', '')) <> '';

    -- Region, numbering sequence and account manager, before anyone tries to raise an order here.
    PERFORM qvm_new_apps.provision_branch_for_quotations(v_branch);
    v_ready := v_ready || jsonb_build_object(
      'customer_id', v_branch,
      'readiness', qvm_new_apps.branch_quotation_readiness(v_branch));
    v_ids := v_ids || v_branch;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', v_ws, 'branch_ids', to_jsonb(v_ids),
    'company_ids', to_jsonb(v_companies), 'primary_company_id', v_primary,
    'unassigned', v_primary IS NULL,
    'branches', v_ready));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_update_workshop(p_workshop_id bigint, p_names jsonb DEFAULT NULL::jsonb, p_city_id integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_city_name text;
BEGIN
  IF NOT qvm_new_apps.can_admin_workshop(p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;

  IF p_city_id IS NOT NULL THEN
    SELECT c.name INTO v_city_name FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
    IF v_city_name IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'City not found');
    END IF;
  END IF;

  UPDATE qvm_new_apps.client_workshops
  SET city_id = COALESCE(p_city_id, city_id), city = COALESCE(v_city_name, city),
      is_active = COALESCE(p_is_active, is_active), updated_by = v_uid, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  PERFORM qvm_new_apps._apply_workshop_details(p_workshop_id, p_details);

  IF p_names IS NOT NULL THEN
    PERFORM qvm_new_apps.assert_names_valid(p_names);
    INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, language_id, name, created_by, updated_by)
    SELECT p_workshop_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
    FROM jsonb_array_elements(p_names) n
    WHERE btrim(COALESCE(n->>'name', '')) <> ''
    ON CONFLICT (workshop_id, language_id) DO UPDATE
      SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

    DELETE FROM qvm_new_apps.client_workshops_descriptions d
     WHERE d.workshop_id = p_workshop_id
       AND d.language_id <> qvm_new_apps.default_language_id()
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                        WHERE (n->>'language_id')::int = d.language_id
                          AND btrim(COALESCE(n->>'name', '')) <> '');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('workshop_id', p_workshop_id));
END $function$;

CREATE OR REPLACE FUNCTION public.admin_create_workshop(
  p_company_ids integer[], p_names jsonb, p_branches jsonb, p_city_id integer DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_create_workshop(p_company_ids, p_names, p_branches, p_city_id, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_create_workshop(integer[], jsonb, jsonb, integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_create_workshop(integer[], jsonb, jsonb, integer, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_update_workshop(
  p_workshop_id bigint, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL, p_is_active boolean DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_update_workshop(p_workshop_id, p_names, p_city_id, p_is_active, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_update_workshop(bigint, jsonb, integer, boolean, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_update_workshop(bigint, jsonb, integer, boolean, jsonb) TO authenticated;

-- A workshop document: the file the upload function stored, given its type and expiry. With no
-- file id, the newest upload of that type on the workshop is the one meant.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_workshop_document(
  p_workshop_id bigint, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  IF NOT qvm_new_apps.can_admin_workshop(p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;
  IF p_doc_type IS NULL OR p_doc_type NOT IN ('cr', 'vat', 'national_address', 'iban', 'other') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown document type');
  END IF;
  SELECT f.id INTO v_id FROM qvm_new_apps.files f
   WHERE f.module_type = 'client_workshops' AND f.module_id = p_workshop_id
     AND (p_file_id IS NULL OR f.id = p_file_id)
     AND (p_file_id IS NOT NULL OR f.field_id = p_doc_type)
   ORDER BY f.created_at DESC LIMIT 1;
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'The uploaded file was not found on this workshop');
  END IF;
  UPDATE qvm_new_apps.files
     SET doc_type = p_doc_type, expires_on = p_expires_on, doc_number = NULLIF(btrim(COALESCE(p_doc_number, '')), '')
   WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', v_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_workshop_document(bigint, text, bigint, date, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_workshop_document(
  p_workshop_id bigint, p_doc_type text, p_file_id bigint DEFAULT NULL, p_expires_on date DEFAULT NULL, p_doc_number text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_workshop_document(p_workshop_id, p_doc_type, p_file_id, p_expires_on, p_doc_number); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_workshop_document(bigint, text, bigint, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_delete_workshop_document(p_file_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_ws bigint;
BEGIN
  SELECT f.module_id INTO v_ws FROM qvm_new_apps.files f WHERE f.id = p_file_id AND f.module_type = 'client_workshops';
  IF v_ws IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Document not found'); END IF;
  IF NOT qvm_new_apps.can_admin_workshop(v_ws) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;
  DELETE FROM qvm_new_apps.files WHERE id = p_file_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('file_id', p_file_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_delete_workshop_document(bigint) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_delete_workshop_document(p_file_id bigint) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_delete_workshop_document(p_file_id); $$;
GRANT EXECUTE ON FUNCTION public.admin_delete_workshop_document(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
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

  WITH workshop_json AS (
    SELECT w.workshop_id, w.company_id,
           jsonb_build_object(
             'workshop_id', w.workshop_id,
             'company_id', w.company_id,
             -- What a company types to link itself to this workshop. Shown on the workshop so it
             -- can be passed on; there is no way to search by it.
             'workshop_code', w.workshop_code,
             'company_ids', COALESCE((SELECT jsonb_agg(wc.company_id ORDER BY wc.company_id)
                                        FROM qvm_new_apps.workshop_companies wc
                                       WHERE wc.workshop_id = w.workshop_id), '[]'::jsonb),
             'display_name', vw.name,
             'city', w.city,
             'city_id', w.city_id,
             'is_active', w.is_active,
             -- Identity and terms, as the workshop form collects them.
             'workshop_type', w.workshop_type,
             'vat_number', w.vat_number,
             'cr_kind', w.cr_kind,
             'cr_number', w.cr_number,
             'account_type', w.account_type,
             'credit_limit', w.credit_limit,
             'credit_term_days', w.credit_term_days,
             'receives_requests', COALESCE(w.receives_requests, true),
             -- The workshop's documents: one row per upload, newest first, with the expiry the
             -- admin recorded. Missing types are for the page to show.
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'client_workshops' AND f.module_id = w.workshop_id), '[]'::jsonb),
             'branch_count', vw.branch_count,
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.client_workshops_descriptions d
                                 WHERE d.workshop_id = w.workshop_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'customer_id', b.customer_id,
                        'display_name', vb.name,
                        'city', b.city,
                        'city_id', b.city_id,
                        'is_bulk_client', b.is_bulk_client,
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                            ORDER BY d.language_id)
                                             FROM qvm_new_apps.client_branches_descriptions d
                                            WHERE d.customer_id = b.customer_id), '[]'::jsonb),
                        'manager_count', (SELECT count(*) FROM qvm_new_apps.user_branches ub
                                           WHERE ub.client_branch_id = b.customer_id AND ub.is_manager),
                        -- Shown per branch because that is where it fails: an order is raised on a
                        -- branch, and this is the list of reasons it would be refused.
                        'readiness', qvm_new_apps.branch_quotation_readiness(b.customer_id))
                      ORDER BY vb.name)
                 FROM qvm_new_apps.client_branches b
                 JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = b.customer_id
                WHERE b.workshop_id = w.workshop_id), '[]'::jsonb),
             'user_count', (SELECT count(*) FROM qvm_new_apps.user_workshops uw WHERE uw.workshop_id = w.workshop_id)
           ) AS ws
    FROM qvm_new_apps.client_workshops w
    JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
  )
  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                               FROM (SELECT language_id, code, english_name, native_name, direction,
                                            is_active, is_default, sort_order
                                       FROM qvm_new_apps.languages WHERE is_active) l), '[]'::jsonb),
      -- Workshops with no company belong to nobody's company, so only Qparts sees the pile.
      'unassigned_workshops', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
        COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                    FROM workshop_json wj
                   WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                                      WHERE wc.workshop_id = wj.workshop_id)), '[]'::jsonb)
        ELSE '[]'::jsonb END,
      'companies', COALESCE((
        SELECT jsonb_agg(co ORDER BY co->>'display_name')
        FROM (
          SELECT jsonb_build_object(
            'company_id', c.company_id,
            'display_name', vc.name,
            'cr_number', c.cr_number,
            'vat_number', c.vat_number,
            'is_active', c.is_active,
            'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                ORDER BY d.language_id)
                                 FROM qvm_new_apps.client_companies_descriptions d
                                WHERE d.company_id = c.company_id), '[]'::jsonb),
            'workshops', COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                                     FROM workshop_json wj
                                     JOIN qvm_new_apps.workshop_companies wc
                                       ON wc.workshop_id = wj.workshop_id
                                    WHERE wc.company_id = c.company_id), '[]'::jsonb)
          ) AS co
          FROM qvm_new_apps.client_companies c
          JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = c.company_id
          -- A Company Admin gets their own companies and no others; can_admin_company answers
          -- true for everything when the caller is a Qparts Admin, so this line is a no-op there.
         WHERE qvm_new_apps.can_admin_company(c.company_id)
        ) s), '[]'::jsonb)
    ))
  INTO v_res;

  RETURN v_res;
END $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 43 $$;
