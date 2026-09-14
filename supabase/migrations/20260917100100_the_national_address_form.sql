-- Addresses take the shape of a Saudi national address.
--
-- One line of text and a city was enough to find a place on a good day. The national address is
-- what a courier, an invoice and a government form all expect: region, city, district, street,
-- building number, secondary number, postal code — and the short address that encodes the lot in
-- eight characters.
--
-- Region, city and district were already rows. What is added here is the rest of the form, on both
-- address tables, so the three trees ask for the same thing in the same order.

ALTER TABLE qvm_new_apps.customer_addresses
  ADD COLUMN IF NOT EXISTS street           text,
  ADD COLUMN IF NOT EXISTS building_number  text,
  ADD COLUMN IF NOT EXISTS secondary_number text,
  ADD COLUMN IF NOT EXISTS short_address    text;

ALTER TABLE qvm_new_apps.vendor_addresses
  ADD COLUMN IF NOT EXISTS street           text,
  ADD COLUMN IF NOT EXISTS building_number  text,
  ADD COLUMN IF NOT EXISTS secondary_number text,
  ADD COLUMN IF NOT EXISTS short_address    text,
  ADD COLUMN IF NOT EXISTS region_id        integer REFERENCES qvm_new_apps.regions(region_id);

-- RRRD2929: four letters then four digits. Checked loosely and only when filled — a wrong-looking
-- code is worth refusing, a missing one is not.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'customer_addresses_short_address_shape') THEN
    ALTER TABLE qvm_new_apps.customer_addresses
      ADD CONSTRAINT customer_addresses_short_address_shape
      CHECK (short_address IS NULL OR short_address ~ '^[A-Za-z]{4}[0-9]{4}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vendor_addresses_short_address_shape') THEN
    ALTER TABLE qvm_new_apps.vendor_addresses
      ADD CONSTRAINT vendor_addresses_short_address_shape
      CHECK (short_address IS NULL OR short_address ~ '^[A-Za-z]{4}[0-9]{4}$');
  END IF;
END $$;

------------------------------------------------------------------------------ a pin names a place

/**
 * What is at this point: the region, the city, and the district if one is near enough.
 *
 * Nearest centre, not point-in-polygon — the boundaries are not in this database and are not worth
 * 58 MB to import. For dropping a pin on a map and filling three dropdowns it is the right trade:
 * occasionally wrong by a street, against three fields nobody can fill from a map at all.
 *
 * The district is only offered when it is within 20 km, and only from the chosen city's own
 * districts. Beyond that the answer is the city alone, which is honest — most of the country has no
 * district on record.
 */
CREATE OR REPLACE FUNCTION qvm_new_apps.place_from_point(p_lat double precision, p_lng double precision)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_city record;
  v_district record;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'A point needs a latitude and a longitude');
  END IF;

  SELECT c.city_id, c.name, c.region_id, c.region_name,
         -- Haversine, in kilometres. The earth is round enough at this scale to matter: a flat
         -- difference of degrees would favour northern cities over southern ones.
         12742 * asin(sqrt(
           sin(radians(c.location_lat - p_lat) / 2) ^ 2
           + cos(radians(p_lat)) * cos(radians(c.location_lat))
           * sin(radians(c.location_lng - p_lng) / 2) ^ 2)) AS km
    INTO v_city
  FROM qvm_new_apps.v_cities c
  WHERE c.is_active AND c.location_lat IS NOT NULL AND c.location_lng IS NOT NULL
  ORDER BY km
  LIMIT 1;

  IF v_city.city_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'city_id', null, 'district_id', null, 'region_id', null));
  END IF;

  SELECT d.district_id, d.name,
         12742 * asin(sqrt(
           sin(radians(d.location_lat - p_lat) / 2) ^ 2
           + cos(radians(p_lat)) * cos(radians(d.location_lat))
           * sin(radians(d.location_lng - p_lng) / 2) ^ 2)) AS km
    INTO v_district
  FROM qvm_new_apps.districts dd
  JOIN qvm_new_apps.v_districts d ON d.district_id = dd.district_id
  WHERE dd.city_id = v_city.city_id
    AND dd.is_active
    AND dd.location_lat IS NOT NULL
  ORDER BY km
  LIMIT 1;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'region_id', v_city.region_id,
    'region_name', v_city.region_name,
    'city_id', v_city.city_id,
    'city_name', v_city.name,
    'city_km', round(v_city.km::numeric, 1),
    'district_id', CASE WHEN v_district.km IS NOT NULL AND v_district.km <= 20 THEN v_district.district_id END,
    'district_name', CASE WHEN v_district.km IS NOT NULL AND v_district.km <= 20 THEN v_district.name END));
END $$;

CREATE OR REPLACE FUNCTION public.place_from_point(p_lat double precision, p_lng double precision)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.place_from_point(p_lat, p_lng) $$;

REVOKE ALL ON FUNCTION public.place_from_point(double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_from_point(double precision, double precision) TO authenticated;

------------------------------------------------------------- the savers take the new fields

-- Dropped rather than left beside the longer one: both would accept the fourteen arguments the
-- frontend used to send, and PostgREST cannot choose between two functions when a call names only
-- the arguments they share.
DROP FUNCTION IF EXISTS public.admin_save_branch_address(
  integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_save_branch_address(
  integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_save_branch_address(
  p_branch_id          integer,
  p_address_id         bigint  DEFAULT NULL,
  p_label              text    DEFAULT NULL,
  p_address_line       text    DEFAULT NULL,
  p_city_id            integer DEFAULT NULL,
  p_district_id        integer DEFAULT NULL,
  p_postal_code        text    DEFAULT NULL,
  p_contact_name       text    DEFAULT NULL,
  p_contact_phone      text    DEFAULT NULL,
  p_geo_lat            numeric DEFAULT NULL,
  p_geo_lng            numeric DEFAULT NULL,
  p_receives_orders    boolean DEFAULT true,
  p_receives_shipments boolean DEFAULT true,
  p_is_default         boolean DEFAULT false,
  p_street             text    DEFAULT NULL,
  p_building_number    text    DEFAULT NULL,
  p_secondary_number   text    DEFAULT NULL,
  p_short_address      text    DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint;
  v_city_text text;
  v_region integer;
  v_customer bigint;
  v_first boolean;
  v_short text := NULLIF(upper(btrim(COALESCE(p_short_address, ''))), '');
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  -- The street is the address now; address_line survives as the free-text line for the addresses
  -- written before this form existed.
  IF btrim(COALESCE(p_street, '')) = '' AND btrim(COALESCE(p_address_line, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'An address needs a street');
  END IF;
  IF v_short IS NOT NULL AND v_short !~ '^[A-Z]{4}[0-9]{4}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'A short address looks like RRRD2929');
  END IF;
  PERFORM qvm_new_apps.assert_district_in_city(p_city_id, p_district_id);

  SELECT vc.name, vc.region_id INTO v_city_text, v_region
  FROM qvm_new_apps.v_cities vc WHERE vc.city_id = p_city_id;

  SELECT c.customer_id INTO v_customer
  FROM qvm_new_apps.client_branches cb
  JOIN qvm_new_apps.customers c ON c.list_data_id = cb.list_data_id AND c.merged_into IS NULL
  WHERE cb.customer_id = p_branch_id;

  IF p_address_id IS NULL THEN
    v_first := NOT EXISTS (SELECT 1 FROM qvm_new_apps.customer_addresses
                            WHERE client_branch_id = p_branch_id AND is_active);

    INSERT INTO qvm_new_apps.customer_addresses
      (customer_id, client_branch_id, label, address_line, city, city_id, district_id, postal_code,
       street, building_number, secondary_number, short_address,
       region_id, geo_lat, geo_lng, contact_name, contact_phone,
       receives_orders, receives_shipments, is_default, created_by)
    VALUES (v_customer, p_branch_id, NULLIF(btrim(COALESCE(p_label, '')), ''),
            NULLIF(btrim(COALESCE(p_address_line, '')), ''),
            v_city_text, p_city_id, p_district_id, NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
            NULLIF(btrim(COALESCE(p_street, '')), ''),
            NULLIF(btrim(COALESCE(p_building_number, '')), ''),
            NULLIF(btrim(COALESCE(p_secondary_number, '')), ''),
            v_short,
            v_region, p_geo_lat, p_geo_lng,
            NULLIF(btrim(COALESCE(p_contact_name, '')), ''), NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
            COALESCE(p_receives_orders, true), COALESCE(p_receives_shipments, true), false, v_uid)
    RETURNING address_id INTO v_id;

    p_is_default := COALESCE(p_is_default, false) OR v_first;
  ELSE
    UPDATE qvm_new_apps.customer_addresses
    SET label = NULLIF(btrim(COALESCE(p_label, '')), ''),
        address_line = NULLIF(btrim(COALESCE(p_address_line, '')), ''),
        city = v_city_text, city_id = p_city_id, district_id = p_district_id,
        postal_code = NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
        street = NULLIF(btrim(COALESCE(p_street, '')), ''),
        building_number = NULLIF(btrim(COALESCE(p_building_number, '')), ''),
        secondary_number = NULLIF(btrim(COALESCE(p_secondary_number, '')), ''),
        short_address = v_short,
        region_id = COALESCE(v_region, region_id),
        geo_lat = p_geo_lat, geo_lng = p_geo_lng,
        contact_name = NULLIF(btrim(COALESCE(p_contact_name, '')), ''),
        contact_phone = NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
        receives_orders = COALESCE(p_receives_orders, true),
        receives_shipments = COALESCE(p_receives_shipments, true),
        updated_at = now()
    WHERE address_id = p_address_id AND client_branch_id = p_branch_id
    RETURNING address_id INTO v_id;

    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'That address does not belong to this branch');
    END IF;
  END IF;

  IF COALESCE(p_is_default, false) THEN
    UPDATE qvm_new_apps.customer_addresses
       SET is_default = false, updated_at = now()
     WHERE client_branch_id = p_branch_id AND address_id <> v_id AND is_default;
    UPDATE qvm_new_apps.customer_addresses
       SET is_default = true, updated_at = now()
     WHERE address_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_branch_address(
  p_branch_id integer, p_address_id bigint DEFAULT NULL, p_label text DEFAULT NULL,
  p_address_line text DEFAULT NULL, p_city_id integer DEFAULT NULL, p_district_id integer DEFAULT NULL,
  p_postal_code text DEFAULT NULL, p_contact_name text DEFAULT NULL, p_contact_phone text DEFAULT NULL,
  p_geo_lat numeric DEFAULT NULL, p_geo_lng numeric DEFAULT NULL,
  p_receives_orders boolean DEFAULT true, p_receives_shipments boolean DEFAULT true,
  p_is_default boolean DEFAULT false,
  p_street text DEFAULT NULL, p_building_number text DEFAULT NULL,
  p_secondary_number text DEFAULT NULL, p_short_address text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_save_branch_address(p_branch_id, p_address_id, p_label, p_address_line,
             p_city_id, p_district_id, p_postal_code, p_contact_name, p_contact_phone,
             p_geo_lat, p_geo_lng, p_receives_orders, p_receives_shipments, p_is_default,
             p_street, p_building_number, p_secondary_number, p_short_address) $$;

GRANT EXECUTE ON FUNCTION public.admin_save_branch_address(integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean, text, text, text, text) TO authenticated;

------------------------------------------------------------------- the vendor side, the same way

DROP FUNCTION IF EXISTS public.admin_save_vendor_branch_address(
  bigint, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_save_vendor_branch_address(
  bigint, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean);

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
  p_is_default       boolean DEFAULT false,
  p_street           text    DEFAULT NULL,
  p_building_number  text    DEFAULT NULL,
  p_secondary_number text    DEFAULT NULL,
  p_short_address    text    DEFAULT NULL
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
  IF NOT qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
  END IF;
  IF btrim(COALESCE(p_street, '')) = '' AND btrim(COALESCE(p_address_line, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'An address needs a street');
  END IF;
  IF v_short IS NOT NULL AND v_short !~ '^[A-Z]{4}[0-9]{4}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'A short address looks like RRRD2929');
  END IF;
  PERFORM qvm_new_apps.assert_district_in_city(p_city_id, p_district_id);

  SELECT c.name, c.region_id INTO v_city, v_region FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;

  IF p_address_id IS NULL THEN
    v_first := NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_addresses
                            WHERE vendor_branch_id = p_vendor_branch_id AND is_active);
    INSERT INTO qvm_new_apps.vendor_addresses
      (vendor_branch_id, label, address_line, city, city_id, district_id, region_id, postal_code,
       street, building_number, secondary_number, short_address,
       geo_lat, geo_lng, contact_name, contact_phone, ships_from, accepts_returns, is_default, created_by)
    VALUES (p_vendor_branch_id, NULLIF(btrim(COALESCE(p_label, '')), ''),
            NULLIF(btrim(COALESCE(p_address_line, '')), ''),
            v_city, p_city_id, p_district_id, v_region, NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
            NULLIF(btrim(COALESCE(p_street, '')), ''),
            NULLIF(btrim(COALESCE(p_building_number, '')), ''),
            NULLIF(btrim(COALESCE(p_secondary_number, '')), ''),
            v_short,
            p_geo_lat, p_geo_lng,
            NULLIF(btrim(COALESCE(p_contact_name, '')), ''), NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
            COALESCE(p_ships_from, true), COALESCE(p_accepts_returns, true), false, v_uid)
    RETURNING address_id INTO v_id;
    p_is_default := COALESCE(p_is_default, false) OR v_first;
  ELSE
    UPDATE qvm_new_apps.vendor_addresses
       SET label = NULLIF(btrim(COALESCE(p_label, '')), ''),
           address_line = NULLIF(btrim(COALESCE(p_address_line, '')), ''),
           city = v_city, city_id = p_city_id, district_id = p_district_id,
           region_id = COALESCE(v_region, region_id),
           postal_code = NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
           street = NULLIF(btrim(COALESCE(p_street, '')), ''),
           building_number = NULLIF(btrim(COALESCE(p_building_number, '')), ''),
           secondary_number = NULLIF(btrim(COALESCE(p_secondary_number, '')), ''),
           short_address = v_short,
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

  IF COALESCE(p_is_default, false) THEN
    UPDATE qvm_new_apps.vendor_addresses SET is_default = false, updated_at = now()
     WHERE vendor_branch_id = p_vendor_branch_id AND address_id <> v_id AND is_default;
    UPDATE qvm_new_apps.vendor_addresses SET is_default = true, updated_at = now() WHERE address_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', v_id));
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_vendor_branch_address(
  p_vendor_branch_id bigint, p_address_id bigint DEFAULT NULL, p_label text DEFAULT NULL,
  p_address_line text DEFAULT NULL, p_city_id integer DEFAULT NULL, p_district_id integer DEFAULT NULL,
  p_postal_code text DEFAULT NULL, p_contact_name text DEFAULT NULL, p_contact_phone text DEFAULT NULL,
  p_geo_lat numeric DEFAULT NULL, p_geo_lng numeric DEFAULT NULL,
  p_ships_from boolean DEFAULT true, p_accepts_returns boolean DEFAULT true,
  p_is_default boolean DEFAULT false,
  p_street text DEFAULT NULL, p_building_number text DEFAULT NULL,
  p_secondary_number text DEFAULT NULL, p_short_address text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_save_vendor_branch_address(p_vendor_branch_id, p_address_id, p_label,
             p_address_line, p_city_id, p_district_id, p_postal_code, p_contact_name, p_contact_phone,
             p_geo_lat, p_geo_lng, p_ships_from, p_accepts_returns, p_is_default,
             p_street, p_building_number, p_secondary_number, p_short_address) $$;

GRANT EXECUTE ON FUNCTION public.admin_save_vendor_branch_address(bigint, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean, text, text, text, text) TO authenticated;

------------------------------------------------------------------ and the readers return them

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_branch_addresses(p_branch_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
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
             'receives_orders', a.receives_orders, 'receives_shipments', a.receives_shipments,
             'is_default', a.is_default, 'is_active', a.is_active)
           ORDER BY a.is_default DESC, a.is_active DESC, a.address_id)
      FROM qvm_new_apps.customer_addresses a
      LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
      LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
      LEFT JOIN qvm_new_apps.v_regions vr   ON vr.region_id = a.region_id
     WHERE a.client_branch_id = p_branch_id), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_vendor_branch_addresses(p_vendor_branch_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
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
             'ships_from', a.ships_from, 'accepts_returns', a.accepts_returns,
             'is_default', a.is_default, 'is_active', a.is_active)
           ORDER BY a.is_default DESC, a.is_active DESC, a.address_id)
      FROM qvm_new_apps.vendor_addresses a
      LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
      LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
      LEFT JOIN qvm_new_apps.v_regions vr   ON vr.region_id = a.region_id
     WHERE a.vendor_branch_id = p_vendor_branch_id), '[]'::jsonb));
END $$;
