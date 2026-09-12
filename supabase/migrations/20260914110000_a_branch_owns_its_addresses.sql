-- A branch owns its addresses, and there may be several.
--
-- customer_addresses has held many addresses per branch since the customers module landed in
-- August: client_branch_id, one default enforced by a partial unique index, receives_orders and
-- receives_shipments so the order form and the shipping board each see the ones that concern them.
-- What it could not express is ownership. customer_id was NOT NULL and pointed at customers, which
-- is keyed one-to-one to a company in list 1 — an assumption the workshop tier removed. A branch
-- belongs to a workshop, and a workshop serves several companies, so "which customer owns this
-- branch's address" stopped having one answer.
--
-- The branch is the owner. customer_id becomes optional and stays for the addresses that are
-- genuinely a company's rather than a branch's; a check keeps every row attached to one or the
-- other, so nothing can be orphaned.
--
-- The city stops being free text. city_id and district_id point at the reference geography, while
-- the old `city` column is kept and written alongside them: the shipments module reads it directly,
-- and this is not the migration to go changing what a carrier payload contains.

ALTER TABLE qvm_new_apps.customer_addresses ALTER COLUMN customer_id DROP NOT NULL;

ALTER TABLE qvm_new_apps.customer_addresses
  ADD COLUMN IF NOT EXISTS city_id     integer REFERENCES qvm_new_apps.cities(city_id),
  ADD COLUMN IF NOT EXISTS district_id integer REFERENCES qvm_new_apps.districts(district_id),
  ADD COLUMN IF NOT EXISTS postal_code text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'customer_addresses_has_an_owner') THEN
    ALTER TABLE qvm_new_apps.customer_addresses
      ADD CONSTRAINT customer_addresses_has_an_owner
      CHECK (customer_id IS NOT NULL OR client_branch_id IS NOT NULL);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_customer_addresses_branch
  ON qvm_new_apps.customer_addresses (client_branch_id) WHERE is_active;

-- A district must sit in the city it is filed under; without this an address can name Riyadh and a
-- district of Jeddah, and nothing downstream would notice.
CREATE OR REPLACE FUNCTION qvm_new_apps.assert_district_in_city(p_city_id integer, p_district_id integer)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF p_district_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.districts d
        WHERE d.district_id = p_district_id AND d.city_id IS NOT DISTINCT FROM p_city_id) THEN
    RAISE EXCEPTION 'That district is not in the chosen city';
  END IF;
END $$;

------------------------------------------------------------------------- the pickers behind the form

-- 4,581 cities is too many to hand over in one payload on every branch form, which is what the
-- no-argument version did. It searches and it caps; the old signature is dropped rather than left
-- beside this one, because PostgREST cannot choose between two functions when a call names only
-- the arguments they share.
DROP FUNCTION IF EXISTS public.list_cities();

CREATE OR REPLACE FUNCTION public.list_cities(
  p_region_id integer DEFAULT NULL,
  p_search    text    DEFAULT NULL,
  p_limit     integer DEFAULT 200
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(x ORDER BY x.sort_order, x.region_code, x.name)
    FROM (
      SELECT c.city_id, c.name, c.region_id, c.region_name, c.region_code,
             c.location_lat, c.location_lng, c.sort_order,
             (SELECT count(*) FROM qvm_new_apps.districts d
               WHERE d.city_id = c.city_id AND d.is_active)::int AS district_count
      FROM qvm_new_apps.v_cities c
      WHERE c.is_active
        AND (p_region_id IS NULL OR c.region_id = p_region_id)
        AND (p_search IS NULL OR btrim(p_search) = '' OR c.name ILIKE '%' || btrim(p_search) || '%')
      ORDER BY c.sort_order, c.region_code, c.name
      LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    ) x), '[]'::jsonb));
$$;

GRANT EXECUTE ON FUNCTION public.list_cities(integer, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_districts(
  p_city_id integer,
  p_search  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('district_id', d.district_id, 'name', d.name)
                     ORDER BY d.name)
      FROM qvm_new_apps.v_districts d
     WHERE d.city_id = p_city_id AND d.is_active
       AND (p_search IS NULL OR btrim(p_search) = '' OR d.name ILIKE '%' || btrim(p_search) || '%')
  ), '[]'::jsonb));
$$;

GRANT EXECUTE ON FUNCTION public.list_districts(integer, text) TO authenticated;

------------------------------------------------------------------------------ the addresses of a branch

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_branch_addresses(p_branch_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
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
             'region_id', a.region_id,
             'geo_lat', a.geo_lat,
             'geo_lng', a.geo_lng,
             'contact_name', a.contact_name,
             'contact_phone', a.contact_phone,
             'receives_orders', a.receives_orders,
             'receives_shipments', a.receives_shipments,
             'is_default', a.is_default,
             'is_active', a.is_active)
           -- Default first, then the live ones, then whatever was switched off.
           ORDER BY a.is_default DESC, a.is_active DESC, a.address_id)
      FROM qvm_new_apps.customer_addresses a
      LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
      LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
     WHERE a.client_branch_id = p_branch_id), '[]'::jsonb));
END $$;

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
  p_is_default         boolean DEFAULT false
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
BEGIN
  IF NOT qvm_new_apps.can_admin_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;
  IF btrim(COALESCE(p_address_line, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'An address needs a line of address');
  END IF;
  PERFORM qvm_new_apps.assert_district_in_city(p_city_id, p_district_id);

  -- The free-text city and the administrative region are filled from the chosen city, because the
  -- shipments module and the older customer screens read those columns and know nothing about
  -- city_id.
  SELECT vc.name, vc.region_id INTO v_city_text, v_region
  FROM qvm_new_apps.v_cities vc WHERE vc.city_id = p_city_id;

  -- customer_id is optional now, but an address that can be attributed to a company still is: the
  -- branch's own company is the honest answer where it exists.
  SELECT c.customer_id INTO v_customer
  FROM qvm_new_apps.client_branches cb
  JOIN qvm_new_apps.customers c ON c.list_data_id = cb.list_data_id AND c.merged_into IS NULL
  WHERE cb.customer_id = p_branch_id;

  IF p_address_id IS NULL THEN
    -- The first address a branch gets is its default, whatever the caller said: an order form with
    -- addresses and no default has nothing to pre-select.
    v_first := NOT EXISTS (SELECT 1 FROM qvm_new_apps.customer_addresses
                            WHERE client_branch_id = p_branch_id AND is_active);

    INSERT INTO qvm_new_apps.customer_addresses
      (customer_id, client_branch_id, label, address_line, city, city_id, district_id, postal_code,
       region_id, geo_lat, geo_lng, contact_name, contact_phone,
       receives_orders, receives_shipments, is_default, created_by)
    VALUES (v_customer, p_branch_id, NULLIF(btrim(COALESCE(p_label, '')), ''), btrim(p_address_line),
            v_city_text, p_city_id, p_district_id, NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
            v_region, p_geo_lat, p_geo_lng,
            NULLIF(btrim(COALESCE(p_contact_name, '')), ''), NULLIF(btrim(COALESCE(p_contact_phone, '')), ''),
            COALESCE(p_receives_orders, true), COALESCE(p_receives_shipments, true),
            false, v_uid)
    RETURNING address_id INTO v_id;

    p_is_default := COALESCE(p_is_default, false) OR v_first;
  ELSE
    UPDATE qvm_new_apps.customer_addresses
    SET label = NULLIF(btrim(COALESCE(p_label, '')), ''),
        address_line = btrim(p_address_line),
        city = v_city_text, city_id = p_city_id, district_id = p_district_id,
        postal_code = NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
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

  -- One default per branch is a unique index, so the old one is stood down before the new one takes
  -- its place — not after, or the index refuses the write.
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

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_branch_address_active(
  p_address_id bigint,
  p_active     boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_branch integer; v_was_default boolean;
BEGIN
  SELECT client_branch_id, is_default INTO v_branch, v_was_default
  FROM qvm_new_apps.customer_addresses WHERE address_id = p_address_id;
  IF v_branch IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Address not found');
  END IF;
  IF NOT qvm_new_apps.can_admin_branch(v_branch) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this branch is not yours to administer');
  END IF;

  UPDATE qvm_new_apps.customer_addresses
     SET is_active = p_active,
         -- Switching off the default leaves the branch with none, so the flag goes with it and the
         -- next surviving address is promoted below.
         is_default = CASE WHEN p_active THEN is_default ELSE false END,
         updated_at = now()
   WHERE address_id = p_address_id;

  IF NOT p_active AND v_was_default THEN
    UPDATE qvm_new_apps.customer_addresses
       SET is_default = true, updated_at = now()
     WHERE address_id = (SELECT address_id FROM qvm_new_apps.customer_addresses
                          WHERE client_branch_id = v_branch AND is_active
                          ORDER BY address_id LIMIT 1);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('address_id', p_address_id));
END $$;

-- Public wrappers: supabase.rpc() resolves against public.
CREATE OR REPLACE FUNCTION public.admin_branch_addresses(p_branch_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_branch_addresses(p_branch_id) $$;

CREATE OR REPLACE FUNCTION public.admin_save_branch_address(
  p_branch_id integer, p_address_id bigint DEFAULT NULL, p_label text DEFAULT NULL,
  p_address_line text DEFAULT NULL, p_city_id integer DEFAULT NULL, p_district_id integer DEFAULT NULL,
  p_postal_code text DEFAULT NULL, p_contact_name text DEFAULT NULL, p_contact_phone text DEFAULT NULL,
  p_geo_lat numeric DEFAULT NULL, p_geo_lng numeric DEFAULT NULL,
  p_receives_orders boolean DEFAULT true, p_receives_shipments boolean DEFAULT true,
  p_is_default boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_save_branch_address(p_branch_id, p_address_id, p_label, p_address_line,
             p_city_id, p_district_id, p_postal_code, p_contact_name, p_contact_phone,
             p_geo_lat, p_geo_lng, p_receives_orders, p_receives_shipments, p_is_default) $$;

CREATE OR REPLACE FUNCTION public.admin_set_branch_address_active(p_address_id bigint, p_active boolean)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_branch_address_active(p_address_id, p_active) $$;

GRANT EXECUTE ON FUNCTION public.admin_branch_addresses(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_branch_address(integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_branch_address_active(bigint, boolean) TO authenticated;

------------------------------------------------------------- the order form sees the same addresses

-- The delivery-address picker on the RFQ form reads this. It already keyed on the branch alone, so
-- branch-owned addresses arrive without changing it; what it lacked was the city and district by
-- name, which is most of what makes one address distinguishable from another in a dropdown.
CREATE OR REPLACE FUNCTION qvm_new_apps.branch_order_addresses(p_branch_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_rows jsonb; v_kind_available boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'address_id', a.address_id,
           'label', a.label,
           'address_line', a.address_line,
           'city', COALESCE(vc.name, a.city),
           'city_id', a.city_id,
           'district', vd.name,
           'district_id', a.district_id,
           'postal_code', a.postal_code,
           'region_id', a.region_id,
           'contact_name', a.contact_name,
           'contact_phone', a.contact_phone,
           'is_default', a.is_default)
         ORDER BY a.is_default DESC, a.address_id), '[]'::jsonb)
    INTO v_rows
    FROM qvm_new_apps.customer_addresses a
    LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
    LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
   WHERE a.client_branch_id = p_branch_id
     AND a.is_active
     AND a.receives_orders;

  SELECT COALESCE(bool_or(c.approvals_enabled), false) INTO v_kind_available
    FROM qvm_new_apps.client_branches b
    JOIN qvm_new_apps.customers c ON c.list_data_id = b.list_data_id AND c.merged_into IS NULL
   WHERE b.customer_id = p_branch_id;

  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'addresses', v_rows,
    'quote_kind_available', v_kind_available));
END $$;
