-- The admin RPCs take a city id instead of typed text.
--
-- The free-text `city` column stays and is kept in step: it is what the 62 functions and every
-- existing dashboard already read, so writing the chosen city's name into it means nothing else has
-- to change today, while city_id is the fact everything new is built on.

CREATE OR REPLACE FUNCTION qvm_new_apps.city_label(p_city_id integer)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT c.name FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
$$;

DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_branch(bigint, jsonb, integer, text, integer, double precision, double precision, boolean);
DROP FUNCTION IF EXISTS public.admin_upsert_branch(bigint, jsonb, integer, text, integer, double precision, double precision, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_branch(
  p_workshop_id  bigint,
  p_names        jsonb,
  p_customer_id  integer DEFAULT NULL,
  p_city_id      integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL,
  p_is_bulk_client boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_company integer; v_id integer; v_default_name text; v_city_name text;
  v_lat double precision; v_lng double precision;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  SELECT company_id INTO v_company FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id;
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

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('customer_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_branch(
  p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL, p_city_id integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL, p_location_lng double precision DEFAULT NULL,
  p_is_bulk_client boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_branch(p_workshop_id, p_names, p_customer_id, p_city_id,
                                          p_location_lat, p_location_lng, p_is_bulk_client); $$;

------------------------------------------------------------------------------ workshop

DROP FUNCTION IF EXISTS qvm_new_apps.admin_create_workshop(integer, jsonb, jsonb, text, integer, double precision, double precision);
DROP FUNCTION IF EXISTS public.admin_create_workshop(integer, jsonb, jsonb, text, integer, double precision, double precision);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(
  p_company_id integer,
  p_names      jsonb,
  p_branches   jsonb,
  p_city_id    integer DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ws bigint; v_branch integer; b jsonb;
  v_ids integer[] := ARRAY[]::integer[];
  v_city_name text; v_lat double precision; v_lng double precision;
  v_bcity integer; v_bname text; v_blat double precision; v_blng double precision;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF p_company_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Company not found');
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
  VALUES (p_company_id, p_city_id, v_city_name, v_lat, v_lng, v_uid, v_uid)
  RETURNING workshop_id INTO v_ws;

  INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, company_id, language_id, name, created_by, updated_by)
  SELECT v_ws, p_company_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> '';

  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    -- A branch with no city of its own sits in the workshop's.
    v_bcity := COALESCE((b->>'city_id')::int, p_city_id);
    SELECT c.name, c.location_lat, c.location_lng INTO v_bname, v_blat, v_blng
    FROM qvm_new_apps.v_cities c WHERE c.city_id = v_bcity;

    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city_id, city, location_lat, location_lng, is_bulk_client)
    VALUES (p_company_id, v_ws,
            (SELECT btrim(n->>'name') FROM jsonb_array_elements(b->'names') n
              WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1),
            v_bcity, v_bname, v_blat, v_blng,
            COALESCE((b->>'is_bulk_client')::boolean, false))
    RETURNING customer_id INTO v_branch;

    INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
    SELECT v_branch, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
    FROM jsonb_array_elements(b->'names') n
    WHERE btrim(COALESCE(n->>'name', '')) <> '';

    v_ids := v_ids || v_branch;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', v_ws, 'branch_ids', to_jsonb(v_ids),
    'company_id', p_company_id, 'unassigned', p_company_id IS NULL));
END $$;

CREATE OR REPLACE FUNCTION public.admin_create_workshop(
  p_company_id integer, p_names jsonb, p_branches jsonb, p_city_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_create_workshop(p_company_id, p_names, p_branches, p_city_id); $$;

DROP FUNCTION IF EXISTS qvm_new_apps.admin_update_workshop(bigint, jsonb, text, boolean);
DROP FUNCTION IF EXISTS public.admin_update_workshop(bigint, jsonb, text, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_update_workshop(
  p_workshop_id bigint,
  p_names       jsonb   DEFAULT NULL,
  p_city_id     integer DEFAULT NULL,
  p_is_active   boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_company integer; v_city_name text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  SELECT company_id INTO v_company FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;

  IF p_city_id IS NOT NULL THEN
    SELECT c.name INTO v_city_name FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
    IF v_city_name IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'City not found');
    END IF;
  END IF;

  UPDATE qvm_new_apps.client_workshops
  SET city_id = COALESCE(p_city_id, city_id),
      city    = COALESCE(v_city_name, city),
      is_active = COALESCE(p_is_active, is_active),
      updated_by = v_uid, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  IF p_names IS NOT NULL THEN
    PERFORM qvm_new_apps.assert_names_valid(p_names);
    INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, company_id, language_id, name, created_by, updated_by)
    SELECT p_workshop_id, v_company, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
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

CREATE OR REPLACE FUNCTION public.admin_update_workshop(
  p_workshop_id bigint, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL,
  p_is_active boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_update_workshop(p_workshop_id, p_names, p_city_id, p_is_active); $$;

GRANT EXECUTE ON FUNCTION public.admin_upsert_branch(bigint, jsonb, integer, integer, double precision, double precision, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_workshop(integer, jsonb, jsonb, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_workshop(bigint, jsonb, integer, boolean) TO authenticated;
