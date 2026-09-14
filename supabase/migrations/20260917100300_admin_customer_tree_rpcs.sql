-- Running the customer tree.
--
-- Access walks the chain: a customer is reachable through the workshops and vendors that own it,
-- and those are reachable through the companies they serve. So can_admin_end_customer asks whether
-- the caller administers any owner of this customer — which for a Qparts Admin is always true, and
-- for a Company Admin is true exactly when one of their companies is at the other end of the chain.
--
-- A customer owned by nobody is Qparts' alone, the same rule the other two trees use for a workshop
-- or a vendor with no company.

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_end_customer(p_end_customer_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR EXISTS (
        SELECT 1 FROM qvm_new_apps.end_customer_owners o
         WHERE o.end_customer_id = p_end_customer_id
           AND ((o.workshop_id IS NOT NULL AND qvm_new_apps.can_admin_workshop(o.workshop_id))
             OR (o.vendor_id   IS NOT NULL AND qvm_new_apps.can_admin_vendor(o.vendor_id))));
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_end_customer_branch(p_branch_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.can_admin_end_customer(
           (SELECT b.end_customer_id FROM qvm_new_apps.end_customer_branches b
             WHERE b.end_customer_branch_id = p_branch_id));
$$;

------------------------------------------------------------------------------ the tree

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_customer_tree()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
             'contact_person', c.contact_person,
             'phone', c.phone,
             'email', c.email,
             'is_active', c.is_active,
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
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.end_customer_branches_descriptions bd
                                            WHERE bd.end_customer_branch_id = b.end_customer_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_end_customer_branches b
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.end_customer_id = c.end_customer_id), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.v_end_customers c
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
    'insurance_companies', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', ic.id, 'name', ic.name)
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
END $$;

------------------------------------------------------------------------------ writing a customer

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_end_customer(
  p_end_customer_id bigint  DEFAULT NULL,
  p_customer_kind   text    DEFAULT NULL,
  p_name            text    DEFAULT NULL,
  p_insurance_company_id bigint DEFAULT NULL,
  p_tax_number      text    DEFAULT NULL,
  p_contact_person  text    DEFAULT NULL,
  p_phone           text    DEFAULT NULL,
  p_email           text    DEFAULT NULL,
  -- Who it belongs to, when creating. 'workshop' or 'vendor' plus that thing's id.
  p_owner_kind      text    DEFAULT NULL,
  p_owner_id        bigint  DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
      (customer_kind, name, insurance_company_id, tax_number, contact_person, phone, email, created_by, updated_by)
    VALUES (v_kind,
            CASE WHEN v_kind = 'insurance' THEN NULL ELSE NULLIF(btrim(COALESCE(p_name, '')), '') END,
            CASE WHEN v_kind = 'insurance' THEN p_insurance_company_id END,
            CASE WHEN v_kind = 'company' THEN NULLIF(btrim(COALESCE(p_tax_number, '')), '') END,
            NULLIF(btrim(COALESCE(p_contact_person, '')), ''),
            NULLIF(btrim(COALESCE(p_phone, '')), ''),
            NULLIF(lower(btrim(COALESCE(p_email, ''))), ''),
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
           updated_by = v_uid, updated_at = now()
     WHERE end_customer_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'end_customer_id', v_id,
    'customer_code', (SELECT customer_code FROM qvm_new_apps.end_customers WHERE end_customer_id = v_id)));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_link_end_customer_by_code(
  p_owner_kind text,
  p_owner_id   bigint,
  p_code       text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_code text := upper(btrim(COALESCE(p_code, '')));
  v_customer bigint;
  v_name text;
BEGIN
  IF p_owner_kind = 'workshop' THEN
    IF NOT qvm_new_apps.can_admin_workshop(p_owner_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
    END IF;
  ELSIF p_owner_kind = 'vendor' THEN
    IF NOT qvm_new_apps.can_admin_vendor(p_owner_id::integer) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
    END IF;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'A customer is linked to a workshop or a vendor');
  END IF;

  IF v_code <> '' AND position('CU-' IN v_code) <> 1 THEN v_code := 'CU-' || v_code; END IF;

  SELECT c.end_customer_id INTO v_customer
  FROM qvm_new_apps.end_customers c WHERE c.customer_code = v_code;
  IF v_customer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No customer has that code');
  END IF;

  SELECT vc.name INTO v_name FROM qvm_new_apps.v_end_customers vc WHERE vc.end_customer_id = v_customer;

  IF EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_owners o
              WHERE o.end_customer_id = v_customer
                AND ((p_owner_kind = 'workshop' AND o.workshop_id = p_owner_id)
                  OR (p_owner_kind = 'vendor' AND o.vendor_id = p_owner_id::integer))) THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'end_customer_id', v_customer, 'customer_name', v_name, 'already_linked', true));
  END IF;

  INSERT INTO qvm_new_apps.end_customer_owners (end_customer_id, workshop_id, vendor_id, created_by)
  VALUES (v_customer,
          CASE WHEN p_owner_kind = 'workshop' THEN p_owner_id END,
          CASE WHEN p_owner_kind = 'vendor' THEN p_owner_id::integer END,
          v_uid);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'end_customer_id', v_customer, 'customer_name', v_name, 'already_linked', false));
END $$;

------------------------------------------------------------------------------ branches

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_end_customer_branch(
  p_end_customer_id bigint,
  p_branch_id       bigint  DEFAULT NULL,
  p_names           jsonb   DEFAULT NULL,
  p_city_id         integer DEFAULT NULL,
  p_is_active       boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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

  INSERT INTO qvm_new_apps.end_customer_branches_descriptions
    (end_customer_branch_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (end_customer_branch_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('end_customer_branch_id', v_id));
END $$;

------------------------------------------------------------------------------ addresses

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_end_customer_addresses(p_branch_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_end_customer_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'address_id', a.address_id, 'label', a.label, 'address_line', a.address_line,
             'street', a.street, 'building_number', a.building_number,
             'secondary_number', a.secondary_number, 'short_address', a.short_address,
             'city_id', a.city_id, 'city_name', COALESCE(vc.name, a.city),
             'district_id', a.district_id, 'district_name', vd.name,
             'region_id', a.region_id, 'region_name', vr.name,
             'postal_code', a.postal_code, 'geo_lat', a.geo_lat, 'geo_lng', a.geo_lng,
             'contact_name', a.contact_name, 'contact_phone', a.contact_phone,
             'is_pickup', a.is_pickup, 'is_delivery', a.is_delivery,
             'is_default', a.is_default, 'is_active', a.is_active)
           ORDER BY a.is_default DESC, a.is_active DESC, a.address_id)
      FROM qvm_new_apps.end_customer_addresses a
      LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
      LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
      LEFT JOIN qvm_new_apps.v_regions vr   ON vr.region_id = a.region_id
     WHERE a.end_customer_branch_id = p_branch_id), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_save_end_customer_address(
  p_branch_id        bigint,
  p_address_id       bigint  DEFAULT NULL,
  p_label            text    DEFAULT NULL,
  p_street           text    DEFAULT NULL,
  p_building_number  text    DEFAULT NULL,
  p_secondary_number text    DEFAULT NULL,
  p_short_address    text    DEFAULT NULL,
  p_city_id          integer DEFAULT NULL,
  p_district_id      integer DEFAULT NULL,
  p_postal_code      text    DEFAULT NULL,
  p_contact_name     text    DEFAULT NULL,
  p_contact_phone    text    DEFAULT NULL,
  p_geo_lat          numeric DEFAULT NULL,
  p_geo_lng          numeric DEFAULT NULL,
  p_is_pickup        boolean DEFAULT true,
  p_is_delivery      boolean DEFAULT true,
  p_is_default       boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint;
  v_city text;
  v_region integer;
  v_first boolean;
  v_short text := NULLIF(upper(btrim(COALESCE(p_short_address, ''))), '');
BEGIN
  IF NOT qvm_new_apps.can_admin_end_customer_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;
  IF btrim(COALESCE(p_street, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'An address needs a street');
  END IF;
  IF v_short IS NOT NULL AND v_short !~ '^[A-Z]{4}[0-9]{4}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'A short address looks like RRRD2929');
  END IF;
  PERFORM qvm_new_apps.assert_district_in_city(p_city_id, p_district_id);

  SELECT c.name, c.region_id INTO v_city, v_region FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;

  IF p_address_id IS NULL THEN
    v_first := NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_addresses
                            WHERE end_customer_branch_id = p_branch_id AND is_active);
    INSERT INTO qvm_new_apps.end_customer_addresses
      (end_customer_branch_id, label, street, building_number, secondary_number, short_address,
       city_id, district_id, region_id, postal_code, city, geo_lat, geo_lng,
       contact_name, contact_phone, is_pickup, is_delivery, is_default, created_by, updated_by)
    VALUES (p_branch_id, NULLIF(btrim(COALESCE(p_label, '')), ''), btrim(p_street),
            NULLIF(btrim(COALESCE(p_building_number, '')), ''),
            NULLIF(btrim(COALESCE(p_secondary_number, '')), ''), v_short,
            p_city_id, p_district_id, v_region, NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
            v_city, p_geo_lat, p_geo_lng,
            NULLIF(btrim(COALESCE(p_contact_name, '')), ''), NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
            COALESCE(p_is_pickup, true), COALESCE(p_is_delivery, true), false, v_uid, v_uid)
    RETURNING address_id INTO v_id;
    p_is_default := COALESCE(p_is_default, false) OR v_first;
  ELSE
    UPDATE qvm_new_apps.end_customer_addresses
       SET label = NULLIF(btrim(COALESCE(p_label, '')), ''),
           street = btrim(p_street),
           building_number = NULLIF(btrim(COALESCE(p_building_number, '')), ''),
           secondary_number = NULLIF(btrim(COALESCE(p_secondary_number, '')), ''),
           short_address = v_short,
           city_id = p_city_id, district_id = p_district_id, region_id = COALESCE(v_region, region_id),
           postal_code = NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
           city = v_city, geo_lat = p_geo_lat, geo_lng = p_geo_lng,
           contact_name = NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
           contact_phone = NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
           is_pickup = COALESCE(p_is_pickup, true),
           is_delivery = COALESCE(p_is_delivery, true),
           updated_by = v_uid, updated_at = now()
     WHERE address_id = p_address_id AND end_customer_branch_id = p_branch_id
    RETURNING address_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'That address does not belong to this branch');
    END IF;
  END IF;

  IF COALESCE(p_is_default, false) THEN
    UPDATE qvm_new_apps.end_customer_addresses SET is_default = false, updated_at = now()
     WHERE end_customer_branch_id = p_branch_id AND address_id <> v_id AND is_default;
    UPDATE qvm_new_apps.end_customer_addresses SET is_default = true, updated_at = now()
     WHERE address_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_end_customer_address_active(
  p_address_id bigint, p_active boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_branch bigint; v_was_default boolean;
BEGIN
  SELECT end_customer_branch_id, is_default INTO v_branch, v_was_default
  FROM qvm_new_apps.end_customer_addresses WHERE address_id = p_address_id;
  IF v_branch IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Address not found');
  END IF;
  IF NOT qvm_new_apps.can_admin_end_customer_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;

  UPDATE qvm_new_apps.end_customer_addresses
     SET is_active = p_active,
         is_default = CASE WHEN p_active THEN is_default ELSE false END,
         updated_at = now()
   WHERE address_id = p_address_id;

  IF NOT p_active AND v_was_default THEN
    UPDATE qvm_new_apps.end_customer_addresses SET is_default = true, updated_at = now()
     WHERE address_id = (SELECT address_id FROM qvm_new_apps.end_customer_addresses
                          WHERE end_customer_branch_id = v_branch AND is_active
                          ORDER BY address_id LIMIT 1);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $$;

------------------------------------------------------------------------------ their users

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_end_customer_users(p_end_customer_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_end_customer(p_end_customer_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
             'user_role', ud.user_role, 'role_name', ld.list_data)
           ORDER BY ud.user_name)
      FROM qvm_new_apps.end_customer_users u
      JOIN qvm_new_apps.user_data ud ON ud.user_id = u.user_id
      LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
     WHERE u.end_customer_id = p_end_customer_id), '[]'::jsonb));
END $$;

------------------------------------------------------------------------------ public wrappers

CREATE OR REPLACE FUNCTION public.admin_get_customer_tree() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_get_customer_tree() $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_end_customer(
  p_end_customer_id bigint DEFAULT NULL, p_customer_kind text DEFAULT NULL, p_name text DEFAULT NULL,
  p_insurance_company_id bigint DEFAULT NULL, p_tax_number text DEFAULT NULL,
  p_contact_person text DEFAULT NULL, p_phone text DEFAULT NULL, p_email text DEFAULT NULL,
  p_owner_kind text DEFAULT NULL, p_owner_id bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_upsert_end_customer(p_end_customer_id, p_customer_kind, p_name,
             p_insurance_company_id, p_tax_number, p_contact_person, p_phone, p_email,
             p_owner_kind, p_owner_id) $$;

CREATE OR REPLACE FUNCTION public.admin_link_end_customer_by_code(
  p_owner_kind text, p_owner_id bigint, p_code text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_link_end_customer_by_code(p_owner_kind, p_owner_id, p_code) $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_end_customer_branch(
  p_end_customer_id bigint, p_branch_id bigint DEFAULT NULL, p_names jsonb DEFAULT NULL,
  p_city_id integer DEFAULT NULL, p_is_active boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_upsert_end_customer_branch(p_end_customer_id, p_branch_id, p_names, p_city_id, p_is_active) $$;

CREATE OR REPLACE FUNCTION public.admin_end_customer_addresses(p_branch_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_end_customer_addresses(p_branch_id) $$;

CREATE OR REPLACE FUNCTION public.admin_save_end_customer_address(
  p_branch_id bigint, p_address_id bigint DEFAULT NULL, p_label text DEFAULT NULL,
  p_street text DEFAULT NULL, p_building_number text DEFAULT NULL, p_secondary_number text DEFAULT NULL,
  p_short_address text DEFAULT NULL, p_city_id integer DEFAULT NULL, p_district_id integer DEFAULT NULL,
  p_postal_code text DEFAULT NULL, p_contact_name text DEFAULT NULL, p_contact_phone text DEFAULT NULL,
  p_geo_lat numeric DEFAULT NULL, p_geo_lng numeric DEFAULT NULL,
  p_is_pickup boolean DEFAULT true, p_is_delivery boolean DEFAULT true,
  p_is_default boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_save_end_customer_address(p_branch_id, p_address_id, p_label, p_street,
             p_building_number, p_secondary_number, p_short_address, p_city_id, p_district_id,
             p_postal_code, p_contact_name, p_contact_phone, p_geo_lat, p_geo_lng,
             p_is_pickup, p_is_delivery, p_is_default) $$;

CREATE OR REPLACE FUNCTION public.admin_set_end_customer_address_active(p_address_id bigint, p_active boolean) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_end_customer_address_active(p_address_id, p_active) $$;

CREATE OR REPLACE FUNCTION public.admin_end_customer_users(p_end_customer_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_end_customer_users(p_end_customer_id) $$;

DO $$
DECLARE fn text;
BEGIN
  FOR fn IN SELECT 'public.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public'
               AND p.proname IN ('admin_get_customer_tree', 'admin_upsert_end_customer',
                                 'admin_link_end_customer_by_code', 'admin_upsert_end_customer_branch',
                                 'admin_end_customer_addresses', 'admin_save_end_customer_address',
                                 'admin_set_end_customer_address_active', 'admin_end_customer_users')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn);
  END LOOP;
END $$;
