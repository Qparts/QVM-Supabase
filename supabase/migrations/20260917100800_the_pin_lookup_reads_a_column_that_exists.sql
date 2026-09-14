-- The map pin could not name a district, because it asked the view for a column the view has not got.
--
-- Every pick came back "the place could not be looked up" and left the three fields alone.
-- place_from_point measures the distance to each district using d.location_lat, where d is
-- v_districts — and v_districts was written before districts had a centre point, so it selects six
-- columns and location_lat is not one of them. PL/pgSQL does not resolve column names when a
-- function is created, only when it runs, so this deployed cleanly and failed on every call.
--
-- Both halves are fixed rather than only the one that was wrong: the view carries the centre now,
-- because anything else asking a district where it is will reach for the same column and find the
-- same hole, and the function measures against the table it filters on so the two cannot disagree
-- again.

CREATE OR REPLACE VIEW qvm_new_apps.v_districts AS
SELECT d.district_id, d.city_id, d.external_id, d.is_active, d.sort_order,
       d.location_lat, d.location_lng,
       t.name, t.language_id AS name_language_id
FROM qvm_new_apps.districts d
LEFT JOIN LATERAL (
  SELECT t.* FROM qvm_new_apps.districts_descriptions t
   WHERE t.district_id = d.district_id
   ORDER BY (t.language_id = qvm_new_apps.current_language_id()) DESC,
            (t.language_id = qvm_new_apps.default_language_id()) DESC,
            t.language_id
   LIMIT 1
) t ON true;

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
      'region_id', null, 'city_id', null, 'district_id', null));
  END IF;

  -- Measured against the table this filters on, so a view that forgets a column cannot break it.
  SELECT dd.district_id,
         (SELECT vd.name FROM qvm_new_apps.v_districts vd WHERE vd.district_id = dd.district_id) AS name,
         12742 * asin(sqrt(
           sin(radians(dd.location_lat - p_lat) / 2) ^ 2
           + cos(radians(p_lat)) * cos(radians(dd.location_lat))
           * sin(radians(dd.location_lng - p_lng) / 2) ^ 2)) AS km
    INTO v_district
  FROM qvm_new_apps.districts dd
  WHERE dd.city_id = v_city.city_id
    AND dd.is_active
    AND dd.location_lat IS NOT NULL
    AND dd.location_lng IS NOT NULL
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
