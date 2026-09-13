-- Running the vendor tree: the same calls the client tree has, against the vendor tables.
--
-- Access follows the same rule throughout. A Qparts Admin reaches everything; a Company Admin
-- reaches a vendor only through a company that vendor serves, which is what can_admin_vendor asks.
-- A vendor serving nobody is Qparts-only, exactly as an unassigned workshop is — it belongs to no
-- company, so no company administers it.

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_vendor(p_vendor_id integer)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR (qvm_new_apps.is_company_admin(auth.uid())
          AND EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies vc
                       WHERE vc.vendor_id = p_vendor_id
                         AND qvm_new_apps.can_admin_company(vc.company_id)));
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.can_admin_vendor(
           (SELECT b.vendor_id FROM qvm_new_apps.vendor_branches b
             WHERE b.vendor_branch_id = p_vendor_branch_id));
$$;

------------------------------------------------------------------------------ the tree

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_vendor_tree()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.vendor_branches_descriptions bd
                                            WHERE bd.vendor_branch_id = b.vendor_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_vendor_branches b
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
END $$;

------------------------------------------------------------------------------ writing

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_vendor(
  p_vendor_id integer DEFAULT NULL,
  p_names     jsonb   DEFAULT NULL,
  p_city_id   integer DEFAULT NULL,
  p_email     text    DEFAULT NULL,
  p_company_ids integer[] DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_vendor_branch(
  p_vendor_id        integer,
  p_vendor_branch_id bigint  DEFAULT NULL,
  p_names            jsonb   DEFAULT NULL,
  p_city_id          integer DEFAULT NULL,
  p_is_active        boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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

  INSERT INTO qvm_new_apps.vendor_branches_descriptions (vendor_branch_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (vendor_branch_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('vendor_branch_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_vendor_companies(
  p_vendor_id integer,
  p_company_ids integer[]
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ids integer[] := COALESCE(p_company_ids, ARRAY[]::integer[]);
  v_primary integer;
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor(p_vendor_id)
     OR NOT COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c)) FROM unnest(v_ids) c), true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;

  DELETE FROM qvm_new_apps.vendor_companies vc
   WHERE vc.vendor_id = p_vendor_id AND NOT (vc.company_id = ANY(v_ids));

  INSERT INTO qvm_new_apps.vendor_companies (vendor_id, company_id, created_by)
  SELECT p_vendor_id, c, v_uid FROM unnest(v_ids) c
  ON CONFLICT (vendor_id, company_id) DO NOTHING;

  SELECT vc.company_id INTO v_primary
  FROM qvm_new_apps.vendor_companies vc WHERE vc.vendor_id = p_vendor_id AND vc.is_primary;
  IF v_primary IS NULL OR NOT (v_primary = ANY(v_ids)) THEN
    UPDATE qvm_new_apps.vendor_companies SET is_primary = false WHERE vendor_id = p_vendor_id AND is_primary;
    UPDATE qvm_new_apps.vendor_companies SET is_primary = true
     WHERE vendor_id = p_vendor_id AND company_id = v_ids[1];
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'vendor_id', p_vendor_id, 'company_ids', to_jsonb(v_ids)));
END $$;

-- The same invite code the workshops use, pointing the other way: a company adds a vendor it does
-- not administer, using the code that vendor gave out.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_link_vendor_by_code(
  p_company_id integer,
  p_code       text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_code text := upper(btrim(COALESCE(p_code, '')));
  v_vendor integer;
  v_name text;
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF v_code <> '' AND position('VN-' IN v_code) <> 1 THEN v_code := 'VN-' || v_code; END IF;

  SELECT v.vendor_id INTO v_vendor FROM qvm_new_apps.vendors v WHERE v.vendor_code = v_code;
  IF v_vendor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No vendor has that code');
  END IF;

  SELECT vv.name INTO v_name FROM qvm_new_apps.v_vendors vv WHERE vv.vendor_id = v_vendor;

  IF EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies
              WHERE vendor_id = v_vendor AND company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'vendor_id', v_vendor, 'vendor_name', v_name, 'already_linked', true));
  END IF;

  INSERT INTO qvm_new_apps.vendor_companies (vendor_id, company_id, created_by)
  VALUES (v_vendor, p_company_id, v_uid);

  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies WHERE vendor_id = v_vendor AND is_primary) THEN
    UPDATE qvm_new_apps.vendor_companies SET is_primary = true
     WHERE vendor_id = v_vendor AND company_id = p_company_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'vendor_id', v_vendor, 'vendor_name', v_name, 'already_linked', false));
END $$;

------------------------------------------------------------------------------ addresses

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_vendor_branch_addresses(p_vendor_branch_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'address_id', a.address_id,
             'label', a.label,
             'address_line', a.address_line,
             'city_id', a.city_id,
             'city_name', COALESCE(vc.name, a.city),
             'district_id', a.district_id,
             'district_name', vd.name,
             'postal_code', a.postal_code,
             'geo_lat', a.geo_lat,
             'geo_lng', a.geo_lng,
             'contact_name', a.contact_name,
             'contact_phone', a.contact_phone,
             'ships_from', a.ships_from,
             'accepts_returns', a.accepts_returns,
             'is_default', a.is_default,
             'is_active', a.is_active)
           ORDER BY a.is_default DESC, a.is_active DESC, a.address_id)
      FROM qvm_new_apps.vendor_addresses a
      LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
      LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
     WHERE a.vendor_branch_id = p_vendor_branch_id), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_save_vendor_branch_address(
  p_vendor_branch_id bigint,
  p_address_id       bigint  DEFAULT NULL,
  p_label            text    DEFAULT NULL,
  p_address_line     text    DEFAULT NULL,
  p_city_id          integer DEFAULT NULL,
  p_district_id      integer DEFAULT NULL,
  p_postal_code      text    DEFAULT NULL,
  p_contact_name     text    DEFAULT NULL,
  p_contact_phone    text    DEFAULT NULL,
  p_geo_lat          numeric DEFAULT NULL,
  p_geo_lng          numeric DEFAULT NULL,
  p_ships_from       boolean DEFAULT true,
  p_accepts_returns  boolean DEFAULT true,
  p_is_default       boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint;
  v_city text;
  v_first boolean;
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;
  IF btrim(COALESCE(p_address_line, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'An address needs a line of address');
  END IF;
  PERFORM qvm_new_apps.assert_district_in_city(p_city_id, p_district_id);

  SELECT c.name INTO v_city FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;

  IF p_address_id IS NULL THEN
    v_first := NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_addresses
                            WHERE vendor_branch_id = p_vendor_branch_id AND is_active);
    INSERT INTO qvm_new_apps.vendor_addresses
      (vendor_branch_id, label, address_line, city, city_id, district_id, postal_code,
       geo_lat, geo_lng, contact_name, contact_phone, ships_from, accepts_returns, is_default, created_by)
    VALUES (p_vendor_branch_id, NULLIF(btrim(COALESCE(p_label, '')), ''), btrim(p_address_line),
            v_city, p_city_id, p_district_id, NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
            p_geo_lat, p_geo_lng,
            NULLIF(btrim(COALESCE(p_contact_name, '')), ''), NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
            COALESCE(p_ships_from, true), COALESCE(p_accepts_returns, true), false, v_uid)
    RETURNING address_id INTO v_id;
    p_is_default := COALESCE(p_is_default, false) OR v_first;
  ELSE
    UPDATE qvm_new_apps.vendor_addresses
       SET label = NULLIF(btrim(COALESCE(p_label, '')), ''),
           address_line = btrim(p_address_line),
           city = v_city, city_id = p_city_id, district_id = p_district_id,
           postal_code = NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
           geo_lat = p_geo_lat, geo_lng = p_geo_lng,
           contact_name = NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
           contact_phone = NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
           ships_from = COALESCE(p_ships_from, true),
           accepts_returns = COALESCE(p_accepts_returns, true),
           updated_by = v_uid, updated_at = now()
     WHERE address_id = p_address_id AND vendor_branch_id = p_vendor_branch_id
    RETURNING address_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'That address does not belong to this branch');
    END IF;
  END IF;

  -- One default per branch is a unique index, so the old one stands down first.
  IF COALESCE(p_is_default, false) THEN
    UPDATE qvm_new_apps.vendor_addresses SET is_default = false, updated_at = now()
     WHERE vendor_branch_id = p_vendor_branch_id AND address_id <> v_id AND is_default;
    UPDATE qvm_new_apps.vendor_addresses SET is_default = true, updated_at = now() WHERE address_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_vendor_address_active(
  p_address_id bigint,
  p_active     boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_branch bigint; v_was_default boolean;
BEGIN
  SELECT vendor_branch_id, is_default INTO v_branch, v_was_default
  FROM qvm_new_apps.vendor_addresses WHERE address_id = p_address_id;
  IF v_branch IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Address not found');
  END IF;
  IF NOT qvm_new_apps.can_admin_vendor_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;

  UPDATE qvm_new_apps.vendor_addresses
     SET is_active = p_active,
         is_default = CASE WHEN p_active THEN is_default ELSE false END,
         updated_at = now()
   WHERE address_id = p_address_id;

  -- Switching off the default leaves the branch without one; the next survivor is promoted.
  IF NOT p_active AND v_was_default THEN
    UPDATE qvm_new_apps.vendor_addresses SET is_default = true, updated_at = now()
     WHERE address_id = (SELECT address_id FROM qvm_new_apps.vendor_addresses
                          WHERE vendor_branch_id = v_branch AND is_active ORDER BY address_id LIMIT 1);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $$;

------------------------------------------------------------------------------ public wrappers

CREATE OR REPLACE FUNCTION public.admin_get_vendor_tree() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_get_vendor_tree() $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_vendor(
  p_vendor_id integer DEFAULT NULL, p_names jsonb DEFAULT NULL, p_city_id integer DEFAULT NULL,
  p_email text DEFAULT NULL, p_company_ids integer[] DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_upsert_vendor(p_vendor_id, p_names, p_city_id, p_email, p_company_ids) $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_vendor_branch(
  p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL, p_names jsonb DEFAULT NULL,
  p_city_id integer DEFAULT NULL, p_is_active boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_upsert_vendor_branch(p_vendor_id, p_vendor_branch_id, p_names, p_city_id, p_is_active) $$;

CREATE OR REPLACE FUNCTION public.admin_set_vendor_companies(p_vendor_id integer, p_company_ids integer[]) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_vendor_companies(p_vendor_id, p_company_ids) $$;

CREATE OR REPLACE FUNCTION public.admin_link_vendor_by_code(p_company_id integer, p_code text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_link_vendor_by_code(p_company_id, p_code) $$;

CREATE OR REPLACE FUNCTION public.admin_vendor_branch_addresses(p_vendor_branch_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_vendor_branch_addresses(p_vendor_branch_id) $$;

CREATE OR REPLACE FUNCTION public.admin_save_vendor_branch_address(
  p_vendor_branch_id bigint, p_address_id bigint DEFAULT NULL, p_label text DEFAULT NULL,
  p_address_line text DEFAULT NULL, p_city_id integer DEFAULT NULL, p_district_id integer DEFAULT NULL,
  p_postal_code text DEFAULT NULL, p_contact_name text DEFAULT NULL, p_contact_phone text DEFAULT NULL,
  p_geo_lat numeric DEFAULT NULL, p_geo_lng numeric DEFAULT NULL,
  p_ships_from boolean DEFAULT true, p_accepts_returns boolean DEFAULT true,
  p_is_default boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_save_vendor_branch_address(p_vendor_branch_id, p_address_id, p_label,
             p_address_line, p_city_id, p_district_id, p_postal_code, p_contact_name, p_contact_phone,
             p_geo_lat, p_geo_lng, p_ships_from, p_accepts_returns, p_is_default) $$;

CREATE OR REPLACE FUNCTION public.admin_set_vendor_address_active(p_address_id bigint, p_active boolean) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_vendor_address_active(p_address_id, p_active) $$;

REVOKE ALL ON FUNCTION public.admin_get_vendor_tree() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_upsert_vendor(integer, jsonb, integer, text, integer[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_vendor_companies(integer, integer[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_link_vendor_by_code(integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_vendor_branch_addresses(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_save_vendor_branch_address(bigint, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_vendor_address_active(bigint, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_get_vendor_tree() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_vendor(integer, jsonb, integer, text, integer[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_vendor_branch(integer, bigint, jsonb, integer, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_companies(integer, integer[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_vendor_by_code(integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_vendor_branch_addresses(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_vendor_branch_address(bigint, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_address_active(bigint, boolean) TO authenticated;
