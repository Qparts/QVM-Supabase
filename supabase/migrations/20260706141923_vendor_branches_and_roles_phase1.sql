-- Synced from QVM/test branch applied migration history (version 20260706141923, name: vendor_branches_and_roles_phase1)
-- Vendor multi-branch + vendor/admin-vendor roles (Phase 1: foundation)
-- - new controlled "vendor_type" list (separate from the existing free-text vendors.vendor_type)
-- - new "Vendor Admin" / "Vendor" user_role values
-- - vendor_branches / vendor_branch_users tables
-- - user_data.user_vendor link
-- - get_user_data() JWT claim extended with vendor_id / admin flag / assigned branches
-- - CRUD RPCs for branches and vendor users

-- 1. New controlled vendor_type list -----------------------------------------------------------

INSERT INTO qvm_new_apps.lists (list_name)
VALUES ('vendor_type');

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT l.list_id, v.name
FROM qvm_new_apps.lists l
CROSS JOIN (VALUES ('تجزئه'), ('جملة'), ('مستورد'), ('وكاله'), ('تشليح'), ('وسيط'), ('داخلي')) AS v(name)
WHERE l.list_name = 'vendor_type';

-- 2. New user_role values for vendor accounts --------------------------------------------------

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT l.list_id, v.name
FROM qvm_new_apps.lists l
CROSS JOIN (VALUES ('Vendor Admin'), ('Vendor')) AS v(name)
WHERE l.list_name = 'user_role';

-- 3. vendors table: new controlled category + receive-quotations flag --------------------------

ALTER TABLE qvm_new_apps.vendors
  ADD COLUMN vendor_type_id integer REFERENCES qvm_new_apps.list_data(list_data_id),
  ADD COLUMN receives_quotations boolean NOT NULL DEFAULT true;

-- 4. vendor_branches ------------------------------------------------------------------------

CREATE TABLE qvm_new_apps.vendor_branches (
  vendor_branch_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vendor_id integer NOT NULL REFERENCES qvm_new_apps.vendors(vendor_id),
  branch_name text NOT NULL,
  city text NOT NULL,
  location_lat double precision,
  location_lng double precision,
  address text,
  brands jsonb NOT NULL DEFAULT '[]'::jsonb,
  categories jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE qvm_new_apps.vendor_branches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "vendor_branches select for app"
  ON qvm_new_apps.vendor_branches
  AS PERMISSIVE FOR SELECT
  TO anon, authenticated
  USING (true);

GRANT SELECT ON TABLE qvm_new_apps.vendor_branches TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON TABLE qvm_new_apps.vendor_branches TO service_role;

-- 5. vendor_branch_users (which non-admin vendor users can see which branch) -------------------

CREATE TABLE qvm_new_apps.vendor_branch_users (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON DELETE CASCADE,
  vendor_branch_id bigint NOT NULL REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, vendor_branch_id)
);

ALTER TABLE qvm_new_apps.vendor_branch_users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "vendor_branch_users select for app"
  ON qvm_new_apps.vendor_branch_users
  AS PERMISSIVE FOR SELECT
  TO anon, authenticated
  USING (true);

GRANT SELECT ON TABLE qvm_new_apps.vendor_branch_users TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON TABLE qvm_new_apps.vendor_branch_users TO service_role;

-- 6. user_data: which vendor account a vendor-type user belongs to ------------------------------

ALTER TABLE qvm_new_apps.user_data
  ADD COLUMN user_vendor integer REFERENCES qvm_new_apps.vendors(vendor_id);

-- 7. get_user_data(): extend JWT claim with vendor context ---------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.get_user_data(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  result jsonb;
  v_vendor_admin_role_id integer;
BEGIN
  SELECT ld.list_data_id INTO v_vendor_admin_role_id
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
  WHERE l.list_name = 'user_role' AND ld.list_data = 'Vendor Admin';

  SELECT jsonb_build_object(
           'user_id', u.user_id,
           'email', u.email,
           'user_name', u.user_name,
           'user_role', ur.list_data,
           'user_role_id', u.user_role,
           'user_type', ut.list_data,
           'user_type_id', u.user_type,
           'user_company', uc.list_data,
           'user_company_id', u.user_company,
           'user_branch', cb.branch_name,
           'user_branch_id', u.user_branch,
           'user_vendor_id', u.user_vendor,
           'is_vendor_admin', (u.user_role IS NOT NULL AND u.user_role = v_vendor_admin_role_id),
           'vendor_branches', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'vendor_branch_id', vb.vendor_branch_id,
                      'branch_name', vb.branch_name,
                      'city', vb.city
                    ) ORDER BY vb.city, vb.branch_name)
             FROM qvm_new_apps.vendor_branch_users vbu
             JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
             WHERE vbu.user_id = u.user_id
           ), '[]'::jsonb)
         )
  INTO result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON u.user_role = ur.list_data_id
  LEFT JOIN qvm_new_apps.list_data ut ON u.user_type = ut.list_data_id
  LEFT JOIN qvm_new_apps.list_data uc ON u.user_company = uc.list_data_id
  LEFT JOIN qvm_new_apps.client_branches cb ON u.user_branch = cb.customer_id
  WHERE u.user_id = p_user_id;

  RETURN result;
END;
$function$;

-- 8. Vendor-admin authorization helper ------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.is_vendor_admin_for(p_vendor_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_ok boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    JOIN qvm_new_apps.lists l ON l.list_id = ur.list_id AND l.list_name = 'user_role'
    WHERE u.user_id = auth.uid()
      AND u.user_vendor = p_vendor_id
      AND ur.list_data = 'Vendor Admin'
  ) INTO v_ok;
  RETURN COALESCE(v_ok, false);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.is_internal_user()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data WHERE user_id = auth.uid() AND user_type = 185
  );
$function$;

-- 9. Branch CRUD RPCs ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches(p_vendor_id integer, p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'vendor_branch_id', vb.vendor_branch_id,
           'vendor_id', vb.vendor_id,
           'branch_name', vb.branch_name,
           'city', vb.city,
           'location_lat', vb.location_lat,
           'location_lng', vb.location_lng,
           'address', vb.address,
           'brands', vb.brands,
           'categories', vb.categories,
           'is_active', vb.is_active
         ) ORDER BY vb.city, vb.branch_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = p_vendor_id
    AND (NOT p_active_only OR vb.is_active);

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendor_branch(p_vendor_id integer, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_new_id bigint;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF NULLIF(trim(p_branch->>'branch_name'), '') IS NULL OR NULLIF(trim(p_branch->>'city'), '') IS NULL THEN
    RAISE EXCEPTION 'branch_name and city are required';
  END IF;

  INSERT INTO qvm_new_apps.vendor_branches (
    vendor_id, branch_name, city, location_lat, location_lng, address, brands, categories, is_active
  ) VALUES (
    p_vendor_id,
    p_branch->>'branch_name',
    p_branch->>'city',
    NULLIF(p_branch->>'location_lat', '')::double precision,
    NULLIF(p_branch->>'location_lng', '')::double precision,
    p_branch->>'address',
    COALESCE(p_branch->'brands', '[]'::jsonb),
    COALESCE(p_branch->'categories', '[]'::jsonb),
    COALESCE((p_branch->>'is_active')::boolean, true)
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.update_vendor_branch(p_vendor_branch_id bigint, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_vendor_id integer;
BEGIN
  SELECT vendor_id INTO v_vendor_id FROM qvm_new_apps.vendor_branches WHERE vendor_branch_id = p_vendor_branch_id;
  IF v_vendor_id IS NULL THEN
    RAISE EXCEPTION 'Branch not found';
  END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE qvm_new_apps.vendor_branches SET
    branch_name = COALESCE(p_branch->>'branch_name', branch_name),
    city = COALESCE(p_branch->>'city', city),
    location_lat = CASE WHEN p_branch ? 'location_lat' THEN NULLIF(p_branch->>'location_lat', '')::double precision ELSE location_lat END,
    location_lng = CASE WHEN p_branch ? 'location_lng' THEN NULLIF(p_branch->>'location_lng', '')::double precision ELSE location_lng END,
    address = COALESCE(p_branch->>'address', address),
    brands = COALESCE(p_branch->'brands', brands),
    categories = COALESCE(p_branch->'categories', categories),
    is_active = COALESCE((p_branch->>'is_active')::boolean, is_active),
    updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_branch_active(p_vendor_branch_id bigint, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_vendor_id integer;
BEGIN
  SELECT vendor_id INTO v_vendor_id FROM qvm_new_apps.vendor_branches WHERE vendor_branch_id = p_vendor_branch_id;
  IF v_vendor_id IS NULL THEN
    RAISE EXCEPTION 'Branch not found';
  END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE qvm_new_apps.vendor_branches SET is_active = p_is_active, updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;

-- 10. Vendor users list + branch (re)assignment ------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_users(p_vendor_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', u.user_id,
           'user_name', u.user_name,
           'email', u.email,
           'user_role', ur.list_data,
           'user_role_id', u.user_role,
           'branches', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'vendor_branch_id', vb.vendor_branch_id,
                      'branch_name', vb.branch_name,
                      'city', vb.city
                    ))
             FROM qvm_new_apps.vendor_branch_users vbu
             JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
             WHERE vbu.user_id = u.user_id
           ), '[]'::jsonb)
         ) ORDER BY u.user_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
  WHERE u.user_vendor = p_vendor_id;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.assign_vendor_user_branches(p_user_id uuid, p_vendor_branch_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = qvm_new_apps, public
AS $function$
DECLARE
  v_vendor_id integer;
  v_bad_branch_count integer;
BEGIN
  SELECT user_vendor INTO v_vendor_id FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_vendor_id IS NULL THEN
    RAISE EXCEPTION 'Vendor user not found';
  END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT count(*) INTO v_bad_branch_count
  FROM unnest(COALESCE(p_vendor_branch_ids, ARRAY[]::bigint[])) bid
  WHERE NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.vendor_branches vb WHERE vb.vendor_branch_id = bid AND vb.vendor_id = v_vendor_id
  );
  IF v_bad_branch_count > 0 THEN
    RAISE EXCEPTION 'One or more branches do not belong to this vendor';
  END IF;

  DELETE FROM qvm_new_apps.vendor_branch_users WHERE user_id = p_user_id;

  INSERT INTO qvm_new_apps.vendor_branch_users (user_id, vendor_branch_id)
  SELECT p_user_id, bid FROM unnest(COALESCE(p_vendor_branch_ids, ARRAY[]::bigint[])) bid;

  RETURN jsonb_build_object('status', true);
END;
$function$;
;
