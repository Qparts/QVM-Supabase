-- Every level runs itself and the level below it.
--
-- Two things. First, a fix: client_branches carries a deferred constraint trigger that runs at
-- commit, after the security-definer RPC has returned, so it ran as the caller and could not read
-- client_workshops (42501 on every branch save). The trigger function is now security definer.
--
-- Second, the access rule the tree is meant to follow: Qparts runs everything; a Company Admin
-- runs their companies and everything under them; a workshop's people (user_workshops) run their
-- workshop and its branches; a branch's manager runs that branch and its addresses. The helpers
-- learn the two lower levels, the RPCs gate on them, and the tree is scoped and flagged per node.
CREATE OR REPLACE FUNCTION qvm_new_apps.assert_workshop_has_branches()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_ws bigint := COALESCE(NEW.workshop_id, OLD.workshop_id);
  v_n  integer;
BEGIN
  IF v_ws IS NULL THEN RETURN NULL; END IF;
  -- A workshop deleted in the same transaction has nothing left to answer for.
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_workshops w WHERE w.workshop_id = v_ws) THEN
    RETURN NULL;
  END IF;
  SELECT count(*) INTO v_n FROM qvm_new_apps.client_branches b WHERE b.workshop_id = v_ws;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Workshop % would be left with no branches. Add a branch, or deactivate the workshop instead.', v_ws
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.branch_manager_role_id()
 RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT list_data_id FROM qvm_new_apps.list_data WHERE list_id = 16 AND list_data = 'Branch Manager' LIMIT 1; $$;

-- The workshop level: anyone scoped to the workshop (user_workshops), as the Users screen assigns.
CREATE OR REPLACE FUNCTION qvm_new_apps.is_workshop_user(p_workshop_id bigint, p_user_id uuid DEFAULT auth.uid())
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                  JOIN qvm_new_apps.user_data ud ON ud.user_id = uw.user_id
                 WHERE uw.workshop_id = p_workshop_id AND uw.user_id = p_user_id AND ud.deleted_at IS NULL); $$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.is_workshop_user(bigint, uuid) TO authenticated;

-- The branch level: the branch's manager, by assignment or by role.
CREATE OR REPLACE FUNCTION qvm_new_apps.is_branch_manager(p_customer_id integer, p_user_id uuid DEFAULT auth.uid())
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub
                  JOIN qvm_new_apps.user_data ud ON ud.user_id = ub.user_id
                 WHERE ub.client_branch_id = p_customer_id AND ub.user_id = p_user_id AND ub.is_manager AND ud.deleted_at IS NULL)
      OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud
                 WHERE ud.user_id = p_user_id AND ud.user_branch = p_customer_id AND ud.deleted_at IS NULL
                   AND ud.user_role = qvm_new_apps.branch_manager_role_id()); $$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.is_branch_manager(integer, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_workshop(p_workshop_id bigint)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $function$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                  WHERE wc.workshop_id = p_workshop_id AND qvm_new_apps.can_admin_company(wc.company_id))
      OR qvm_new_apps.is_workshop_user(p_workshop_id, auth.uid());
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_branch(p_customer_id integer)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $function$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb
                  WHERE cb.customer_id = p_customer_id AND qvm_new_apps.can_admin_workshop(cb.workshop_id))
      OR qvm_new_apps.is_branch_manager(p_customer_id, auth.uid());
$function$;

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
  -- The workshop's people create and edit its branches; a branch's own manager edits that branch alone.
  IF NOT (qvm_new_apps.can_admin_workshop(p_workshop_id)
          OR (p_customer_id IS NOT NULL AND qvm_new_apps.can_admin_branch(p_customer_id)
              AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb
                           WHERE cb.customer_id = p_customer_id AND cb.workshop_id = p_workshop_id))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
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

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_address_type(p_address_id bigint, p_address_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_branch integer;
BEGIN
  SELECT a.client_branch_id INTO v_branch FROM qvm_new_apps.customer_addresses a WHERE a.address_id = p_address_id;
  IF v_branch IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Address not found'); END IF;
  IF NOT qvm_new_apps.can_admin_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  IF p_address_type IS NOT NULL AND p_address_type NOT IN ('warehouse', 'showroom', 'office', 'pickup') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown address type');
  END IF;
  UPDATE qvm_new_apps.customer_addresses SET address_type = p_address_type WHERE address_id = p_address_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  -- Every level opens the tree and sees what it runs: Qparts everything, a Company Admin their
  -- companies, a workshop's people their workshop, a branch manager their branch.
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = v_uid)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub WHERE ub.user_id = v_uid AND ub.is_manager)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.deleted_at IS NULL
                        AND ud.user_branch IS NOT NULL AND ud.user_role = qvm_new_apps.branch_manager_role_id())) THEN
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
             'can_edit', qvm_new_apps.can_admin_workshop(w.workshop_id),
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
                        'can_edit', qvm_new_apps.can_admin_branch(b.customer_id),
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
                WHERE b.workshop_id = w.workshop_id
                  -- A branch manager sees their own branch; the workshop's people see them all.
                  AND (qvm_new_apps.can_admin_workshop(w.workshop_id) OR qvm_new_apps.is_branch_manager(b.customer_id))), '[]'::jsonb),
             'user_count', (SELECT count(*) FROM qvm_new_apps.user_workshops uw WHERE uw.workshop_id = w.workshop_id)
           ) AS ws
    FROM qvm_new_apps.client_workshops w
    JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
   WHERE qvm_new_apps.can_admin_workshop(w.workshop_id)
      OR EXISTS (SELECT 1 FROM qvm_new_apps.client_branches b
                  WHERE b.workshop_id = w.workshop_id AND qvm_new_apps.is_branch_manager(b.customer_id))
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
            'can_edit', qvm_new_apps.can_admin_company(c.company_id),
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
            -- Or a company one of the caller's workshops or branches sits under: read-only at
            -- the company level, editable below.
            OR EXISTS (SELECT 1 FROM workshop_json wj
                       JOIN qvm_new_apps.workshop_companies wc ON wc.workshop_id = wj.workshop_id
                      WHERE wc.company_id = c.company_id)
        ) s), '[]'::jsonb),
      'viewer', jsonb_build_object('level',
        CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN 'qparts'
             WHEN qvm_new_apps.is_company_admin(v_uid) THEN 'company'
             WHEN EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = v_uid) THEN 'workshop'
             ELSE 'branch' END)
    ))
  INTO v_res;

  RETURN v_res;
END $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 45 $$;
