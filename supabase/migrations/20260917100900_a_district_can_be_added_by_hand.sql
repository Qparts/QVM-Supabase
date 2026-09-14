-- A district that is not in the reference data can be typed in.
--
-- The import covers 152 cities of 4,581. That is not a gap in the import: the National Address
-- programme delineates districts for the places that have them, and the other 4,429 are towns and
-- villages where a district is not a thing anybody uses. "This city has no districts on record" is
-- true far more often than it is a problem.
--
-- It is a problem when it is wrong — a city that grew, a district everyone locally names and no
-- dataset has caught up with. So one can be added, and it is added for everyone, because an address
-- field that only its author can fill is not shared data.
--
-- Each one records where it came from. A district somebody typed is a weaker fact than one that
-- arrived with an official id — worth keeping apart for the day anybody asks why two spellings of
-- the same place exist, or wants to reconcile against a newer import.

ALTER TABLE qvm_new_apps.districts
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'reference'
    CHECK (source IN ('reference', 'manual'));

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_add_district(
  p_city_id integer,
  p_names   jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id integer;
  v_default_name text;
  v_lat double precision;
  v_lng double precision;
BEGIN
  -- The same people who run the trees. A district is reference data everyone then sees, so it is
  -- not something any signed-in account should be able to invent.
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.cities WHERE city_id = p_city_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That city does not exist');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  -- Refused rather than allowed to become a second spelling of a district that is already there.
  IF EXISTS (
    SELECT 1 FROM qvm_new_apps.districts d
    JOIN qvm_new_apps.districts_descriptions dd ON dd.district_id = d.district_id
    WHERE d.city_id = p_city_id
      AND lower(btrim(dd.name)) = lower(btrim(v_default_name))
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', format('%s is already a district of this city', v_default_name));
  END IF;

  -- The city's own centre, so a pin dropped nearby still resolves to something sensible. It is a
  -- worse position than a real centroid and a much better one than none: without it this district
  -- is invisible to the map lookup entirely.
  SELECT c.location_lat, c.location_lng INTO v_lat, v_lng
  FROM qvm_new_apps.cities c WHERE c.city_id = p_city_id;

  INSERT INTO qvm_new_apps.districts (city_id, source, location_lat, location_lng, sort_order, created_by, updated_by)
  VALUES (p_city_id, 'manual', v_lat, v_lng, 500, v_uid, v_uid)
  RETURNING district_id INTO v_id;

  INSERT INTO qvm_new_apps.districts_descriptions (district_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> '';

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'district_id', v_id, 'name', v_default_name));
END $$;

CREATE OR REPLACE FUNCTION public.admin_add_district(p_city_id integer, p_names jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_add_district(p_city_id, p_names) $$;

REVOKE ALL ON FUNCTION public.admin_add_district(integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_add_district(integer, jsonb) TO authenticated;

-- The list says which are which, so a manually added one can be recognised.
CREATE OR REPLACE FUNCTION public.list_districts(
  p_city_id integer,
  p_search  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'district_id', d.district_id, 'name', d.name,
             'source', dd.source)
           ORDER BY d.name)
      FROM qvm_new_apps.v_districts d
      JOIN qvm_new_apps.districts dd ON dd.district_id = d.district_id
     WHERE d.city_id = p_city_id AND d.is_active
       AND (p_search IS NULL OR btrim(p_search) = '' OR d.name ILIKE '%' || btrim(p_search) || '%')
  ), '[]'::jsonb));
$$;

REVOKE ALL ON FUNCTION public.list_districts(integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_districts(integer, text) TO authenticated;
