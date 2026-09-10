-- Everything the Qparts admin does to the client tree, from the frontend.
--
-- One gate for the lot: user_type 185 and user_role 172. These functions are SECURITY DEFINER —
-- they write tables the client role cannot touch directly — so the check is the only thing standing
-- between a normal internal user and the company list. It is written once and called from every
-- entry point rather than repeated inline, so there is one place to be right.
--
-- Names always travel as `p_names`:  [{"language_id": 1, "name": "PAC"}, {"language_id": 2, "name": "باك"}]
-- and must carry the default language. A record whose only name is in a language a reader does not
-- speak still resolves through the view's fallback, but a record with NO default-language name is
-- one nobody can find in the language the platform falls back to.

CREATE OR REPLACE FUNCTION qvm_new_apps.is_qparts_admin(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud
                  WHERE ud.user_id = p_user_id AND ud.user_type = 185 AND ud.user_role = 172
                    AND ud.deleted_at IS NULL);
$$;

-- Machine-to-machine callers: create_client_user runs with the service role, where auth.uid() is
-- NULL, so the plain admin check would refuse it. The service role is trusted by definition — it
-- IS the key that could write these tables directly — and the edge function does its own
-- Qparts-Admin check on the caller before it gets here.
CREATE OR REPLACE FUNCTION qvm_new_apps.is_qparts_admin_or_service()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR COALESCE(current_setting('request.jwt.claims', true)::jsonb->>'role', '') = 'service_role';
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.assert_names_valid(p_names jsonb)
RETURNS void LANGUAGE plpgsql STABLE SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_default int := qvm_new_apps.default_language_id();
BEGIN
  IF p_names IS NULL OR jsonb_typeof(p_names) <> 'array' OR jsonb_array_length(p_names) = 0 THEN
    RAISE EXCEPTION 'At least one name is required' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_names) n
     WHERE (n->>'language_id')::int = v_default AND btrim(COALESCE(n->>'name', '')) <> ''
  ) THEN
    RAISE EXCEPTION 'A name in the default language is required'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_names) n
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.languages l
                        WHERE l.language_id = (n->>'language_id')::int AND l.is_active)
  ) THEN
    RAISE EXCEPTION 'A name was given for a language that is unknown or switched off'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
END $$;

------------------------------------------------------------------------------ languages

-- SECURITY DEFINER with no gate would hand the language table to anyone holding the anon key.
-- The admin view carries usage counts and inactive languages; the public one, list_active_languages,
-- is the version everyone else gets.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_languages()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT CASE WHEN NOT qvm_new_apps.is_qparts_admin(auth.uid())
              THEN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only')
              ELSE jsonb_build_object('success', true, 'data',
                     COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id), '[]'::jsonb))
         END
  FROM (SELECT language_id, code, english_name, native_name, direction, is_active, is_default, sort_order,
               (SELECT count(*) FROM qvm_new_apps.client_companies_descriptions d WHERE d.language_id = lg.language_id)
             + (SELECT count(*) FROM qvm_new_apps.client_workshops_descriptions d WHERE d.language_id = lg.language_id)
             + (SELECT count(*) FROM qvm_new_apps.client_branches_descriptions  d WHERE d.language_id = lg.language_id) AS usage_count
          FROM qvm_new_apps.languages lg) l;
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_language(
  p_language_id  integer DEFAULT NULL,
  p_code         text    DEFAULT NULL,
  p_english_name text    DEFAULT NULL,
  p_native_name  text    DEFAULT NULL,
  p_direction    text    DEFAULT 'ltr',
  p_is_active    boolean DEFAULT true,
  p_sort_order   integer DEFAULT 100
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_id integer; v_is_default boolean;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF p_direction NOT IN ('ltr', 'rtl') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Direction must be ltr or rtl');
  END IF;

  IF p_language_id IS NULL THEN
    IF btrim(COALESCE(p_code, '')) = '' OR btrim(COALESCE(p_english_name, '')) = ''
       OR btrim(COALESCE(p_native_name, '')) = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'Code, English name and native name are all required');
    END IF;
    INSERT INTO qvm_new_apps.languages (code, english_name, native_name, direction, is_active, sort_order, created_by, updated_by)
    VALUES (lower(btrim(p_code)), btrim(p_english_name), btrim(p_native_name), p_direction,
            COALESCE(p_is_active, true), COALESCE(p_sort_order, 100), v_uid, v_uid)
    RETURNING language_id INTO v_id;
  ELSE
    SELECT is_default INTO v_is_default FROM qvm_new_apps.languages WHERE language_id = p_language_id;
    IF v_is_default IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Language not found');
    END IF;
    -- The default language is the fallback every reader lands on; switching it off would leave
    -- records with nothing to fall back to.
    IF v_is_default AND COALESCE(p_is_active, true) = false THEN
      RETURN jsonb_build_object('success', false, 'error', 'The default language cannot be switched off. Make another language the default first.');
    END IF;
    UPDATE qvm_new_apps.languages
    SET code         = COALESCE(lower(NULLIF(btrim(p_code), '')), code),
        english_name = COALESCE(NULLIF(btrim(p_english_name), ''), english_name),
        native_name  = COALESCE(NULLIF(btrim(p_native_name), ''), native_name),
        direction    = COALESCE(p_direction, direction),
        is_active    = COALESCE(p_is_active, is_active),
        sort_order   = COALESCE(p_sort_order, sort_order),
        updated_by = v_uid, updated_at = now()
    WHERE language_id = p_language_id
    RETURNING language_id INTO v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('language_id', v_id));
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('success', false, 'error', format('The code "%s" is already in use', lower(btrim(p_code))));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_default_language(p_language_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.languages WHERE language_id = p_language_id AND is_active) THEN
    RETURN jsonb_build_object('success', false, 'error', 'An inactive or unknown language cannot be the default');
  END IF;
  -- Cleared first: the partial unique index allows only one row with is_default true at a time.
  UPDATE qvm_new_apps.languages SET is_default = false, updated_by = v_uid, updated_at = now() WHERE is_default;
  UPDATE qvm_new_apps.languages SET is_default = true,  updated_by = v_uid, updated_at = now() WHERE language_id = p_language_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('language_id', p_language_id));
END $$;

------------------------------------------------------------------------------ the tree, for editing
--
-- Returns every language's name for every record, not the resolved one: this feeds the admin
-- screen, which edits translations rather than reading them.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                               FROM (SELECT language_id, code, english_name, native_name, direction,
                                            is_active, is_default, sort_order
                                       FROM qvm_new_apps.languages WHERE is_active) l), '[]'::jsonb),
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
            'workshops', COALESCE((
              SELECT jsonb_agg(ws ORDER BY ws->>'display_name')
              FROM (
                SELECT jsonb_build_object(
                  'workshop_id', w.workshop_id,
                  'company_id', w.company_id,
                  'display_name', vw.name,
                  'city', w.city,
                  'is_active', w.is_active,
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
                             'is_bulk_client', b.is_bulk_client,
                             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                                 ORDER BY d.language_id)
                                                  FROM qvm_new_apps.client_branches_descriptions d
                                                 WHERE d.customer_id = b.customer_id), '[]'::jsonb),
                             'manager_count', (SELECT count(*) FROM qvm_new_apps.user_branches ub
                                                WHERE ub.client_branch_id = b.customer_id AND ub.is_manager))
                           ORDER BY vb.name)
                      FROM qvm_new_apps.client_branches b
                      JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = b.customer_id
                     WHERE b.workshop_id = w.workshop_id), '[]'::jsonb),
                  'user_count', (SELECT count(*) FROM qvm_new_apps.user_workshops uw WHERE uw.workshop_id = w.workshop_id)
                ) AS ws
                FROM qvm_new_apps.client_workshops w
                JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
               WHERE w.company_id = c.company_id
              ) t), '[]'::jsonb)
          ) AS co
          FROM qvm_new_apps.client_companies c
          JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = c.company_id
        ) s), '[]'::jsonb)
    ))
  INTO v_res;

  RETURN v_res;
END $$;

------------------------------------------------------------------------------ writes

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_company(
  p_company_id integer DEFAULT NULL,
  p_names      jsonb   DEFAULT NULL,
  p_cr_number  text    DEFAULT NULL,
  p_vat_number text    DEFAULT NULL,
  p_is_active  boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_id integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  IF p_company_id IS NULL THEN
    INSERT INTO qvm_new_apps.client_companies (cr_number, vat_number, is_active, created_by, updated_by)
    VALUES (p_cr_number, p_vat_number, COALESCE(p_is_active, true), v_uid, v_uid)
    RETURNING company_id INTO v_id;
    -- list_data carried companies before this; a new one is mirrored there so the 62 functions
    -- still reading list 1 keep seeing the whole set until they are moved over.
    INSERT INTO qvm_new_apps.list_data (list_data_id, list_id, list_data)
    VALUES (v_id, 1, (SELECT n->>'name' FROM jsonb_array_elements(p_names) n
                       WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1))
    ON CONFLICT (list_data_id) DO NOTHING;
  ELSE
    UPDATE qvm_new_apps.client_companies
    SET cr_number = p_cr_number, vat_number = p_vat_number,
        is_active = COALESCE(p_is_active, is_active), updated_by = v_uid, updated_at = now()
    WHERE company_id = p_company_id
    RETURNING company_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Company not found');
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.client_companies_descriptions (company_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (company_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  -- A language cleared in the editor is removed rather than left behind as a stale translation.
  DELETE FROM qvm_new_apps.client_companies_descriptions d
   WHERE d.company_id = v_id
     AND d.language_id <> qvm_new_apps.default_language_id()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = d.language_id
                        AND btrim(COALESCE(n->>'name', '')) <> '');

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('company_id', v_id));
END $$;

-- Workshop and its first branches in one transaction. There is no other way to make a workshop,
-- which is what makes "a workshop cannot exist without branches" true rather than merely intended.
--
-- p_branches: [{"names": [{"language_id":1,"name":"Olaya"}], "city": "Riyadh",
--               "location_lat": 24.7, "location_lng": 46.6, "is_bulk_client": false}]
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(
  p_company_id integer,
  p_names      jsonb,
  p_branches   jsonb,
  p_city       text DEFAULT NULL,
  p_region_id  integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ws bigint;
  v_branch integer;
  b jsonb;
  v_ids integer[] := ARRAY[]::integer[];
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Company not found');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  IF p_branches IS NULL OR jsonb_typeof(p_branches) <> 'array' OR jsonb_array_length(p_branches) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'A workshop must be created with at least one branch');
  END IF;
  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    PERFORM qvm_new_apps.assert_names_valid(b->'names');
  END LOOP;

  INSERT INTO qvm_new_apps.client_workshops (company_id, city, region_id, location_lat, location_lng, created_by, updated_by)
  VALUES (p_company_id, p_city, p_region_id, p_location_lat, p_location_lng, v_uid, v_uid)
  RETURNING workshop_id INTO v_ws;

  INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, company_id, language_id, name, created_by, updated_by)
  SELECT v_ws, p_company_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> '';

  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city, region_id, location_lat, location_lng, is_bulk_client)
    VALUES (p_company_id, v_ws,
            (SELECT btrim(n->>'name') FROM jsonb_array_elements(b->'names') n
              WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1),
            COALESCE(b->>'city', p_city),
            COALESCE((b->>'region_id')::int, p_region_id),
            COALESCE((b->>'location_lat')::double precision, p_location_lat),
            COALESCE((b->>'location_lng')::double precision, p_location_lng),
            COALESCE((b->>'is_bulk_client')::boolean, false))
    RETURNING customer_id INTO v_branch;

    INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
    SELECT v_branch, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
    FROM jsonb_array_elements(b->'names') n
    WHERE btrim(COALESCE(n->>'name', '')) <> '';

    v_ids := v_ids || v_branch;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data',
    jsonb_build_object('workshop_id', v_ws, 'branch_ids', to_jsonb(v_ids)));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_update_workshop(
  p_workshop_id bigint,
  p_names       jsonb   DEFAULT NULL,
  p_city        text    DEFAULT NULL,
  p_is_active   boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_company integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  SELECT company_id INTO v_company FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id;
  IF v_company IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;

  UPDATE qvm_new_apps.client_workshops
  SET city = COALESCE(p_city, city), is_active = COALESCE(p_is_active, is_active),
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

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_branch(
  p_workshop_id  bigint,
  p_names        jsonb,
  p_customer_id  integer DEFAULT NULL,
  p_city         text    DEFAULT NULL,
  p_region_id    integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL,
  p_is_bulk_client boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_company integer; v_id integer; v_default_name text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  SELECT company_id INTO v_company FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id;
  IF v_company IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF p_customer_id IS NULL THEN
    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city, region_id, location_lat, location_lng, is_bulk_client)
    VALUES (v_company, p_workshop_id, v_default_name, p_city, p_region_id,
            p_location_lat, p_location_lng, COALESCE(p_is_bulk_client, false))
    RETURNING customer_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.client_branches
    SET workshop_id = p_workshop_id, list_data_id = v_company, branch_name = v_default_name,
        city = COALESCE(p_city, city), region_id = COALESCE(p_region_id, region_id),
        location_lat = COALESCE(p_location_lat, location_lat),
        location_lng = COALESCE(p_location_lng, location_lng),
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

------------------------------------------------------------------------------ people

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_workshop_users(p_workshop_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
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
END $$;

-- Sets a client user's scope in one call: which workshops they belong to, and which branches they
-- manage. Passing an empty list clears that side; passing NULL leaves it alone.
--
-- p_branches: [{"customer_id": 121, "is_manager": true}]
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_user_scope(
  p_user_id      uuid,
  p_workshop_ids bigint[] DEFAULT NULL,
  p_branches     jsonb    DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_company integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin_or_service() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data WHERE user_id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  IF p_workshop_ids IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id
       AND NOT (workshop_id = ANY(p_workshop_ids));
    INSERT INTO qvm_new_apps.user_workshops (user_id, workshop_id, created_by)
    SELECT p_user_id, w, v_uid FROM unnest(p_workshop_ids) w
    ON CONFLICT (user_id, workshop_id) DO NOTHING;
  END IF;

  IF p_branches IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_branches ub
     WHERE ub.user_id = p_user_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_branches) b
                        WHERE (b->>'customer_id')::int = ub.client_branch_id);
    INSERT INTO qvm_new_apps.user_branches (user_id, client_branch_id, is_manager, created_by)
    SELECT p_user_id, (b->>'customer_id')::int, COALESCE((b->>'is_manager')::boolean, false), v_uid
    FROM jsonb_array_elements(p_branches) b
    ON CONFLICT (user_id, client_branch_id) DO UPDATE SET is_manager = EXCLUDED.is_manager;
  END IF;

  -- user_data still carries a single company and branch; keep them pointing somewhere real so the
  -- screens that read them directly do not show an account with no home.
  SELECT w.company_id INTO v_company
  FROM qvm_new_apps.user_workshops uw JOIN qvm_new_apps.client_workshops w ON w.workshop_id = uw.workshop_id
  WHERE uw.user_id = p_user_id LIMIT 1;

  UPDATE qvm_new_apps.user_data ud
  SET user_company = COALESCE(v_company, ud.user_company),
      user_branch  = COALESCE((SELECT ub.client_branch_id FROM qvm_new_apps.user_branches ub
                                WHERE ub.user_id = p_user_id ORDER BY ub.is_manager DESC LIMIT 1),
                              (SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
                                 JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
                                WHERE uw.user_id = p_user_id LIMIT 1),
                              ud.user_branch),
      updated_at = now()
  WHERE ud.user_id = p_user_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user_id', p_user_id,
    'branch_ids', to_jsonb(qvm_new_apps.effective_branch_ids(p_user_id))));
END $$;

------------------------------------------------------------------------------ public wrappers
-- supabase.rpc() with no schema resolves against public.

CREATE OR REPLACE FUNCTION public.admin_list_languages() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_list_languages(); $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_language(
  p_language_id integer DEFAULT NULL, p_code text DEFAULT NULL, p_english_name text DEFAULT NULL,
  p_native_name text DEFAULT NULL, p_direction text DEFAULT 'ltr', p_is_active boolean DEFAULT true,
  p_sort_order integer DEFAULT 100) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_language(p_language_id, p_code, p_english_name, p_native_name,
                                            p_direction, p_is_active, p_sort_order); $$;

CREATE OR REPLACE FUNCTION public.admin_set_default_language(p_language_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_default_language(p_language_id); $$;

CREATE OR REPLACE FUNCTION public.admin_get_client_tree() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$ SELECT qvm_new_apps.admin_get_client_tree(); $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_company(
  p_company_id integer DEFAULT NULL, p_names jsonb DEFAULT NULL, p_cr_number text DEFAULT NULL,
  p_vat_number text DEFAULT NULL, p_is_active boolean DEFAULT true) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_company(p_company_id, p_names, p_cr_number, p_vat_number, p_is_active); $$;

CREATE OR REPLACE FUNCTION public.admin_create_workshop(
  p_company_id integer, p_names jsonb, p_branches jsonb, p_city text DEFAULT NULL,
  p_region_id integer DEFAULT NULL, p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_create_workshop(p_company_id, p_names, p_branches, p_city, p_region_id,
                                            p_location_lat, p_location_lng); $$;

CREATE OR REPLACE FUNCTION public.admin_update_workshop(
  p_workshop_id bigint, p_names jsonb DEFAULT NULL, p_city text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_update_workshop(p_workshop_id, p_names, p_city, p_is_active); $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_branch(
  p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL, p_city text DEFAULT NULL,
  p_region_id integer DEFAULT NULL, p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL, p_is_bulk_client boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_upsert_branch(p_workshop_id, p_names, p_customer_id, p_city, p_region_id,
                                          p_location_lat, p_location_lng, p_is_bulk_client); $$;

CREATE OR REPLACE FUNCTION public.admin_list_workshop_users(p_workshop_id bigint) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_list_workshop_users(p_workshop_id); $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_scope(
  p_user_id uuid, p_workshop_ids bigint[] DEFAULT NULL, p_branches jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_user_scope(p_user_id, p_workshop_ids, p_branches); $$;

-- Every language the app may render in, readable by any signed-in user: the language switcher
-- needs it before anyone is known to be an admin.
CREATE OR REPLACE FUNCTION public.list_active_languages() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data',
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
                       'language_id', l.language_id, 'code', l.code,
                       'english_name', l.english_name, 'native_name', l.native_name,
                       'direction', l.direction, 'is_default', l.is_default)
                     ORDER BY l.sort_order, l.language_id)
                FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb));
$$;

GRANT EXECUTE ON FUNCTION
  public.admin_list_languages(), public.admin_set_default_language(integer),
  public.admin_get_client_tree(), public.admin_list_workshop_users(bigint),
  public.list_active_languages()
TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_language(integer, text, text, text, text, boolean, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_company(integer, jsonb, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_workshop(integer, jsonb, jsonb, text, integer, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_workshop(bigint, jsonb, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_branch(bigint, jsonb, integer, text, integer, double precision, double precision, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_scope(uuid, bigint[], jsonb) TO authenticated;
