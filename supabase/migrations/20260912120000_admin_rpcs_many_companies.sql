-- The admin RPCs speak in sets of companies, and leave every branch able to take an order.

DROP FUNCTION IF EXISTS qvm_new_apps.admin_assign_workshop_company(bigint, integer);
DROP FUNCTION IF EXISTS public.admin_assign_workshop_company(bigint, integer);

-- The whole set, every time. A workshop's companies are a list the admin edits, not a sequence of
-- add and remove calls whose order decides the outcome.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_workshop_companies(
  p_workshop_id bigint,
  p_company_ids integer[]
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ids integer[] := COALESCE(p_company_ids, ARRAY[]::integer[]);
  v_primary integer;
  v_orders integer;
  r record;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
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
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_workshop_companies(
  p_workshop_id bigint, p_company_ids integer[]) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_workshop_companies(p_workshop_id, p_company_ids); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_workshop_companies(bigint, integer[]) TO authenticated;

------------------------------------------------------------------------------ create / edit

DROP FUNCTION IF EXISTS qvm_new_apps.admin_create_workshop(integer, jsonb, jsonb, integer);
DROP FUNCTION IF EXISTS public.admin_create_workshop(integer, jsonb, jsonb, integer);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(
  p_company_ids integer[],
  p_names       jsonb,
  p_branches    jsonb,
  p_city_id     integer DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
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
END $$;

CREATE OR REPLACE FUNCTION public.admin_create_workshop(
  p_company_ids integer[], p_names jsonb, p_branches jsonb, p_city_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_create_workshop(p_company_ids, p_names, p_branches, p_city_id); $$;
GRANT EXECUTE ON FUNCTION public.admin_create_workshop(integer[], jsonb, jsonb, integer) TO authenticated;

-- The workshop's descriptions no longer carry a company, and a new branch provisions itself.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_update_workshop(
  p_workshop_id bigint,
  p_names       jsonb   DEFAULT NULL,
  p_city_id     integer DEFAULT NULL,
  p_is_active   boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_city_name text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
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
END $$;
