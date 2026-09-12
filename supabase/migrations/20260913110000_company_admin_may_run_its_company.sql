-- Company Admin may run their own company, through the same functions.
--
-- Each gate becomes a question about the thing being changed rather than about the caller alone:
-- can_admin_company for a company, can_admin_workshop for a workshop, can_admin_branch for a
-- branch. A Qparts Admin answers yes to all of them, so nothing about that role changes; a Company
-- Admin answers yes only for the companies they are on.
--
-- The refusals now say which thing was refused, because "Qparts Admin only" is both wrong and
-- unhelpful here: the caller may well be an administrator, of something else.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(p_company_ids integer[], p_names jsonb, p_branches jsonb, p_city_id integer DEFAULT NULL::integer)
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

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_workshop_companies(p_workshop_id bigint, p_company_ids integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ids integer[] := COALESCE(p_company_ids, ARRAY[]::integer[]);
  v_primary integer;
  v_orders integer;
  r record;
BEGIN
  -- Both sides have to be theirs: the workshop as it stands, and every company it will serve.
  IF NOT qvm_new_apps.can_admin_workshop(p_workshop_id)
     OR NOT COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c)) FROM unnest(v_ids) c), true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) c
              WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = c)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'One of the companies does not exist');
  END IF;

  -- Removing every company from a workshop whose branches already carry orders would strand them
  -- outside each company-scoped view. Narrowing the set is fine; emptying it is not.
  IF array_length(v_ids, 1) IS NULL THEN
    SELECT count(*) INTO v_orders
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    WHERE cb.workshop_id = p_workshop_id;
    IF v_orders > 0 THEN
      RETURN jsonb_build_object('success', false, 'error',
        format('This workshop has %s order line(s) and cannot be left with no company.', v_orders));
    END IF;
  END IF;

  DELETE FROM qvm_new_apps.workshop_companies wc
   WHERE wc.workshop_id = p_workshop_id AND NOT (wc.company_id = ANY(v_ids));

  INSERT INTO qvm_new_apps.workshop_companies (workshop_id, company_id, created_by)
  SELECT p_workshop_id, c, v_uid FROM unnest(v_ids) c
  ON CONFLICT (workshop_id, company_id) DO NOTHING;

  -- Keep exactly one primary: the one already marked if it survived, else the first given.
  SELECT wc.company_id INTO v_primary
  FROM qvm_new_apps.workshop_companies wc
  WHERE wc.workshop_id = p_workshop_id AND wc.is_primary;

  IF v_primary IS NULL OR NOT (v_primary = ANY(v_ids)) THEN
    v_primary := v_ids[1];
    UPDATE qvm_new_apps.workshop_companies SET is_primary = false
     WHERE workshop_id = p_workshop_id AND is_primary;
    UPDATE qvm_new_apps.workshop_companies SET is_primary = true
     WHERE workshop_id = p_workshop_id AND company_id = v_primary;
  END IF;

  -- The primary is what client_branches.list_data_id follows, so the dashboards that group by it
  -- keep working while they still read the branch rather than the order.
  UPDATE qvm_new_apps.client_workshops
  SET company_id = v_primary, updated_by = v_uid, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  UPDATE qvm_new_apps.client_branches
  SET list_data_id = v_primary, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  UPDATE qvm_new_apps.user_data ud
  SET user_company = v_primary, updated_at = now()
  WHERE v_primary IS NOT NULL
    AND EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                 WHERE uw.user_id = ud.user_id AND uw.workshop_id = p_workshop_id);

  -- Every branch needs a numbering sequence for every company now served.
  FOR r IN SELECT customer_id FROM qvm_new_apps.client_branches WHERE workshop_id = p_workshop_id
  LOOP
    PERFORM qvm_new_apps.provision_branch_for_quotations(r.customer_id);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', p_workshop_id,
    'company_ids', to_jsonb(v_ids),
    'primary_company_id', v_primary));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_update_workshop(p_workshop_id bigint, p_names jsonb DEFAULT NULL::jsonb, p_city_id integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean)
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

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_workshop_users(p_workshop_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT qvm_new_apps.can_admin_workshop(p_workshop_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id,
             'user_name', ud.user_name,
             'email', ud.email,
             'user_role', ud.user_role,
             'role_name', ld.list_data,
             'is_workshop_user', EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw2
                                          WHERE uw2.user_id = ud.user_id AND uw2.workshop_id = p_workshop_id),
             'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                            'customer_id', ub.client_branch_id,
                                            'is_manager', ub.is_manager))
                                     FROM qvm_new_apps.user_branches ub
                                     JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ub.client_branch_id
                                    WHERE ub.user_id = ud.user_id AND cb.workshop_id = p_workshop_id), '[]'::jsonb))
           ORDER BY ud.user_name)
    FROM qvm_new_apps.user_data ud
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
   WHERE ud.deleted_at IS NULL
     AND (EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = ud.user_id AND uw.workshop_id = p_workshop_id)
       OR EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub
                    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ub.client_branch_id
                   WHERE ub.user_id = ud.user_id AND cb.workshop_id = p_workshop_id))
  ), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_branch(p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL::integer, p_city_id integer DEFAULT NULL::integer, p_location_lat double precision DEFAULT NULL::double precision, p_location_lng double precision DEFAULT NULL::double precision, p_is_bulk_client boolean DEFAULT NULL::boolean)
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

  -- Region, order-number sequences and an account manager, so the branch can take an order the
  -- moment it exists rather than failing at the first RFQ with a message that names none of this.
  PERFORM qvm_new_apps.provision_branch_for_quotations(v_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', v_id,
    'readiness', qvm_new_apps.branch_quotation_readiness(v_id)));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_managers(p_customer_id integer, p_user_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ids uuid[] := COALESCE(p_user_ids, ARRAY[]::uuid[]);
  v_n   integer;
  v_slot smallint;
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
  END IF;

  v_n := COALESCE(array_length(v_ids, 1), 0);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'A branch needs at least one manager — without one its orders are refused before they are numbered.');
  END IF;
  IF v_n > 4 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Up to four managers per branch: the coverage chain is a main and three substitutes.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) u
              WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data
                                 WHERE user_id = u AND deleted_at IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'One of those users does not exist');
  END IF;
  IF (SELECT count(DISTINCT u) FROM unnest(v_ids) u) <> v_n THEN
    RETURN jsonb_build_object('success', false, 'error', 'The same person is listed twice');
  END IF;

  -- Only the chain. The allocation is recalculated by the trigger on this table, from this plus
  -- each manager's attendance; writing it here is how the duplicate rows appeared.
  DELETE FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_customer_id;

  FOREACH v_slot IN ARRAY ARRAY[1, 2, 3]::smallint[] LOOP
    INSERT INTO qvm_new_apps.account_manager_branches
      (customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager)
    VALUES (p_customer_id, v_slot, v_ids[1], v_ids[2], v_ids[3], v_ids[4]);
  END LOOP;

  -- A branch with no allocation row at all cannot be served, and the baseline only creates rows for
  -- branches it walks; this makes sure this one has its three before anyone raises an order.
  INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
  SELECT p_customer_id, s, now()
  FROM generate_series(1, 3) s
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a
                     WHERE a.customer_id = p_customer_id AND a.slot_number = s);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'manager_count', v_n,
    'readiness', qvm_new_apps.branch_quotation_readiness(p_customer_id)));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_branch_managers(p_customer_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', c.uid, 'rank', c.rank,
             'user_name', ud.user_name, 'email', ud.email, 'role_name', ld.list_data,
             'on_duty', (SELECT COALESCE(jsonb_agg(d ORDER BY ord), '[]'::jsonb)
                           FROM (SELECT 'Sat' AS d, 1 AS ord WHERE a.saturday  = c.uid
                                 UNION ALL SELECT 'Sun', 2 WHERE a.sunday    = c.uid
                                 UNION ALL SELECT 'Mon', 3 WHERE a.monday    = c.uid
                                 UNION ALL SELECT 'Tue', 4 WHERE a.tuesday   = c.uid
                                 UNION ALL SELECT 'Wed', 5 WHERE a.wednesday = c.uid
                                 UNION ALL SELECT 'Thu', 6 WHERE a.thursday  = c.uid) x))
           ORDER BY c.rank)
    FROM (
      SELECT b.main_account_manager AS uid, 1 AS rank FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.main_account_manager IS NOT NULL
      UNION ALL
      SELECT b.first_substitute, 2 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.first_substitute IS NOT NULL
      UNION ALL
      SELECT b.second_substitute, 3 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.second_substitute IS NOT NULL
      UNION ALL
      SELECT b.fallback_account_manager, 4 FROM qvm_new_apps.account_manager_branches b
       WHERE b.customer_id = p_customer_id AND b.slot_number = 1 AND b.fallback_account_manager IS NOT NULL
    ) c
    JOIN qvm_new_apps.user_data ud ON ud.user_id = c.uid
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
    LEFT JOIN qvm_new_apps.account_manager_allocations a
           ON a.customer_id = p_customer_id AND a.slot_number = 1
  ), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_account_managers()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  -- A Company Admin reads it too: they are the ones naming managers for their own branches.
  IF NOT (qvm_new_apps.is_qparts_admin(auth.uid()) OR qvm_new_apps.is_company_admin(auth.uid())) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', u.user_id, 'user_name', u.user_name, 'email', u.email,
             'role_name', u.role_name, 'user_role', u.user_role,
             'is_internal', u.user_type = 185,
             'branch_count', u.branch_count,
             'is_current', u.branch_count > 0)
           ORDER BY u.branch_count DESC, u.user_name)
    FROM (
      SELECT ud.user_id, ud.user_name, ud.email, ud.user_type, ud.user_role, ld.list_data AS role_name,
             (SELECT count(DISTINCT b.customer_id)
                FROM qvm_new_apps.account_manager_branches b
               WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                    b.second_substitute, b.fallback_account_manager)) AS branch_count
      FROM qvm_new_apps.user_data ud
      LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
      -- Branch Manager, Client Admin, Qparts Admin. Anyone already allocated stays listed whatever
      -- their role, because removing them from the list would not remove them from the branches
      -- they already own — it would only hide who is there.
      WHERE ud.deleted_at IS NULL
        AND (ud.user_role IN (195, 170, 172)
             OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches b
                         WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                              b.second_substitute, b.fallback_account_manager)))
    ) u
  ), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_company_users(p_company_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
             'user_type', ud.user_type, 'user_role', ud.user_role, 'role_name', ld.list_data,
             'branch_count', COALESCE(array_length(qvm_new_apps.effective_branch_ids(ud.user_id), 1), 0))
           ORDER BY ud.user_name)
    FROM qvm_new_apps.user_data ud
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
    JOIN qvm_new_apps.user_companies uc ON uc.user_id = ud.user_id AND uc.company_id = p_company_id
   WHERE ud.deleted_at IS NULL
  ), '[]'::jsonb));
END $function$;
