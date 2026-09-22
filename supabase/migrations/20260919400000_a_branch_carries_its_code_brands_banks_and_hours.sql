-- A branch carries its code, brands, sections, bank accounts and working hours.
--
-- The add-workshop design's branch step asks for more than a name and a city. The wizard's branch
-- cards and the branch modal on Companies & Workshops now collect it, an address names its kind,
-- and the tree returns it all.
ALTER TABLE qvm_new_apps.client_branches
  ADD COLUMN IF NOT EXISTS branch_code text,
  ADD COLUMN IF NOT EXISTS brand_ids integer[],
  ADD COLUMN IF NOT EXISTS part_category_ids integer[],
  ADD COLUMN IF NOT EXISTS banks jsonb,
  ADD COLUMN IF NOT EXISTS hours_mode text,
  ADD COLUMN IF NOT EXISTS working_hours jsonb;
ALTER TABLE qvm_new_apps.client_branches DROP CONSTRAINT IF EXISTS client_branches_hours_mode_check;
ALTER TABLE qvm_new_apps.client_branches ADD CONSTRAINT client_branches_hours_mode_check
  CHECK (hours_mode IS NULL OR hours_mode IN ('247', 'schedule'));
ALTER TABLE qvm_new_apps.customer_addresses ADD COLUMN IF NOT EXISTS address_type text;
ALTER TABLE qvm_new_apps.customer_addresses DROP CONSTRAINT IF EXISTS customer_addresses_address_type_check;
ALTER TABLE qvm_new_apps.customer_addresses ADD CONSTRAINT customer_addresses_address_type_check
  CHECK (address_type IS NULL OR address_type IN ('warehouse', 'showroom', 'office', 'pickup'));

-- Applies whichever branch detail keys the form sent; absent keys are left alone.
CREATE OR REPLACE FUNCTION qvm_new_apps._apply_branch_details(p_customer_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'hours_mode' AND NULLIF(btrim(p->>'hours_mode'), '') IS NOT NULL AND (p->>'hours_mode') NOT IN ('247', 'schedule') THEN
    RAISE EXCEPTION 'Unknown working-hours mode';
  END IF;
  UPDATE qvm_new_apps.client_branches b
     SET branch_code       = CASE WHEN p ? 'branch_code' THEN NULLIF(btrim(p->>'branch_code'), '') ELSE b.branch_code END,
         brand_ids         = CASE WHEN p ? 'brand_ids' THEN
                               (SELECT COALESCE(array_agg(x::int), '{}') FROM jsonb_array_elements_text(COALESCE(p->'brand_ids', '[]'::jsonb)) x)
                             ELSE b.brand_ids END,
         part_category_ids = CASE WHEN p ? 'part_category_ids' THEN
                               (SELECT COALESCE(array_agg(x::int), '{}') FROM jsonb_array_elements_text(COALESCE(p->'part_category_ids', '[]'::jsonb)) x)
                             ELSE b.part_category_ids END,
         banks             = CASE WHEN p ? 'banks' THEN COALESCE(p->'banks', '[]'::jsonb) ELSE b.banks END,
         hours_mode        = CASE WHEN p ? 'hours_mode' THEN NULLIF(btrim(p->>'hours_mode'), '') ELSE b.hours_mode END,
         working_hours     = CASE WHEN p ? 'working_hours' THEN COALESCE(p->'working_hours', '[]'::jsonb) ELSE b.working_hours END,
         updated_at = now()
   WHERE b.customer_id = p_customer_id;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps._apply_branch_details(integer, jsonb) FROM PUBLIC;

-- An address says what it is: a warehouse, a showroom, an office or a pickup point.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_address_type(p_address_id bigint, p_address_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_ws bigint;
BEGIN
  SELECT b.workshop_id INTO v_ws
    FROM qvm_new_apps.customer_addresses a JOIN qvm_new_apps.client_branches b ON b.customer_id = a.client_branch_id
   WHERE a.address_id = p_address_id;
  IF v_ws IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Address not found'); END IF;
  IF NOT qvm_new_apps.can_admin_workshop(v_ws) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;
  IF p_address_type IS NOT NULL AND p_address_type NOT IN ('warehouse', 'showroom', 'office', 'pickup') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown address type');
  END IF;
  UPDATE qvm_new_apps.customer_addresses SET address_type = p_address_type WHERE address_id = p_address_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_branch_address_type(bigint, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_branch_address_type(p_address_id bigint, p_address_type text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_branch_address_type(p_address_id, p_address_type); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_branch_address_type(bigint, text) TO authenticated;

-- Trailing defaults make new overloads; the old shapes go so a call stays unambiguous.
DROP FUNCTION IF EXISTS public.admin_upsert_branch(bigint, jsonb, integer, integer, double precision, double precision, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_branch(bigint, jsonb, integer, integer, double precision, double precision, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_branch(p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL::integer, p_city_id integer DEFAULT NULL::integer, p_location_lat double precision DEFAULT NULL::double precision, p_location_lng double precision DEFAULT NULL::double precision, p_is_bulk_client boolean DEFAULT NULL::boolean, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_company integer; v_id integer; v_default_name text; v_city_name text;
  v_lat double precision; v_lng double precision;
BEGIN
  IF NOT qvm_new_apps.can_admin_workshop(p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;
  -- The primary company only. A branch serves every company its workshop does; list_data_id is the
  -- one the older dashboards group by, not a statement about who the work is for.
  SELECT w.company_id INTO v_company FROM qvm_new_apps.client_workshops w WHERE w.workshop_id = p_workshop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  IF p_city_id IS NOT NULL THEN
    SELECT c.name, c.location_lat, c.location_lng INTO v_city_name, v_lat, v_lng
    FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
    IF v_city_name IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'City not found');
    END IF;
  END IF;

  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF p_customer_id IS NULL THEN
    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city_id, city, location_lat, location_lng, is_bulk_client)
    -- The city's own coordinates are the starting point; a branch keeps its own once given one.
    VALUES (v_company, p_workshop_id, v_default_name, p_city_id, v_city_name,
            COALESCE(p_location_lat, v_lat), COALESCE(p_location_lng, v_lng),
            COALESCE(p_is_bulk_client, false))
    RETURNING customer_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.client_branches
    SET workshop_id = p_workshop_id, list_data_id = v_company, branch_name = v_default_name,
        city_id = COALESCE(p_city_id, city_id),
        city    = COALESCE(v_city_name, city),
        location_lat = COALESCE(p_location_lat, location_lat, v_lat),
        location_lng = COALESCE(p_location_lng, location_lng, v_lng),
        is_bulk_client = COALESCE(p_is_bulk_client, is_bulk_client),
        updated_at = now()
    WHERE customer_id = p_customer_id
    RETURNING customer_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (customer_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  DELETE FROM qvm_new_apps.client_branches_descriptions d
   WHERE d.customer_id = v_id
     AND d.language_id <> qvm_new_apps.default_language_id()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = d.language_id
                        AND btrim(COALESCE(n->>'name', '')) <> '');

  -- Code, brands, sections, bank accounts and working hours, when the form carried them.
  PERFORM qvm_new_apps._apply_branch_details(v_id, p_details);

  -- Region, order-number sequences and an account manager, so the branch can take an order the
  -- moment it exists rather than failing at the first RFQ with a message that names none of this.
  PERFORM qvm_new_apps.provision_branch_for_quotations(v_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', v_id,
    'readiness', qvm_new_apps.branch_quotation_readiness(v_id)));
END $function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_branch(bigint, jsonb, integer, integer, double precision, double precision, boolean, jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_upsert_branch(
  p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL, p_city_id integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL, p_location_lng double precision DEFAULT NULL, p_is_bulk_client boolean DEFAULT NULL, p_details jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_branch(p_workshop_id, p_names, p_customer_id, p_city_id, p_location_lat, p_location_lng, p_is_bulk_client, p_details); $$;
GRANT EXECUTE ON FUNCTION public.admin_upsert_branch(bigint, jsonb, integer, integer, double precision, double precision, boolean, jsonb) TO authenticated;

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

    PERFORM qvm_new_apps._apply_branch_details(v_branch, b->'details');

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
                        'branch_code', b.branch_code,
                        'brand_ids', COALESCE(to_jsonb(b.brand_ids), '[]'::jsonb),
                        'part_category_ids', COALESCE(to_jsonb(b.part_category_ids), '[]'::jsonb),
                        'banks', COALESCE(b.banks, '[]'::jsonb),
                        'hours_mode', b.hours_mode,
                        'working_hours', COALESCE(b.working_hours, '[]'::jsonb),
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
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 44 $$;
