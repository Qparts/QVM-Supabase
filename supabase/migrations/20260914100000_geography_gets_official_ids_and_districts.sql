-- Official identifiers for the geography, and the districts under a city.
--
-- The regions and 110 cities seeded in September were typed by hand from public sources. They are
-- correct as far as they go, but they are ours alone: nothing outside this database agrees on what
-- "city 42" is, and a courier integration or an address import has no way to line up with them.
--
-- The open dataset at github.com/homaily/Saudi-Arabia-Regions-Cities-and-Districts is the usual
-- reference for Saudi geography — 13 regions, 4,581 cities and 3,732 districts, each with a stable
-- id, an Arabic and an English name, and a centre point. This adopts its identifiers as an
-- `external_id` beside our own rather than re-keying: client_branches.city_id already points at our
-- ids, and order_number_sequences is built on our region_id.
--
-- Provenance: github.com/homaily/Saudi-Arabia-Regions-Cities-and-Districts, which states GPL-2.0.
-- The facts themselves — the name and position of a city — are not the kind of thing copyright
-- protects, and they originate with the General Authority for Statistics and the National Address
-- programme; the licence attaches to that repository's compilation of them. Recorded here so the
-- source of these 8,300 rows is never a mystery, and so the question can be answered if it is ever
-- asked.
--
-- Only the plain data is taken. The dataset also ships boundary polygons — 16.6 MB for regions,
-- 58.4 MB for districts — and nothing here draws a boundary.
--
-- The 110 existing cities are matched on region plus their Arabic name, normalised for the alef,
-- teh-marbuta and definite-article spellings that make the same place look like two. That links 106
-- outright. Three more are the same place under a different transliteration — Mahayil Asir/Muhayil,
-- Duba, Al Uwayqilah — and are linked by hand after checking their coordinates agree to within a
-- few kilometres. NEOM is left standalone on purpose: the nearest dataset entry is the village of
-- Sharma, 4 km away, and merging the two would quietly rename it.

ALTER TABLE qvm_new_apps.regions ADD COLUMN IF NOT EXISTS external_code text;
ALTER TABLE qvm_new_apps.cities  ADD COLUMN IF NOT EXISTS external_id integer;
CREATE UNIQUE INDEX IF NOT EXISTS uq_regions_external_code ON qvm_new_apps.regions (external_code)
  WHERE external_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cities_external_id ON qvm_new_apps.cities (external_id)
  WHERE external_id IS NOT NULL;

UPDATE qvm_new_apps.regions r SET external_code = v.code, updated_at = now()
FROM (VALUES
  ('riyadh', 'RD'),
  ('makkah', 'MQ'),
  ('madinah', 'MN'),
  ('qassim', 'QA'),
  ('eastern', 'SQ'),
  ('asir', 'AS'),
  ('tabuk', 'TB'),
  ('hail', 'HA'),
  ('northern', 'SH'),
  ('jazan', 'GA'),
  ('najran', 'NG'),
  ('bahah', 'BA'),
  ('jouf', 'GO')
) AS v(slug, code)
WHERE r.region_code = v.slug AND r.external_code IS DISTINCT FROM v.code;

-- Our hand-seeded cities adopt the official id for the same place.
UPDATE qvm_new_apps.cities c SET external_id = v.ext_id, updated_at = now()
FROM (VALUES
  ('Riyadh', 3),
  ('Diriyah', 828),
  ('Al Kharj', 1061),
  ('Al Majmaah', 24),
  ('Al Zulfi', 270),
  ('Al Quwayiyah', 880),
  ('Al Dawadmi', 669),
  ('Wadi ad-Dawasir', 1351),
  ('Afif', 418),
  ('Shaqra', 500),
  ('Al Muzahimiyah', 990),
  ('Hotat Bani Tamim', 3161),
  ('Layla', 3174),
  ('Huraymila', 795),
  ('Thadiq', 443),
  ('Al Ghat', 306),
  ('Marat', 820),
  ('Rumah', 294),
  ('Al Hariq', 3158),
  ('Makkah', 6),
  ('Jeddah', 18),
  ('Taif', 5),
  ('Rabigh', 377),
  ('Al Qunfudhah', 1625),
  ('Al Lith', 1390),
  ('Khulais', 1105),
  ('Al Jumum', 1257),
  ('Turbah', 2156),
  ('Ranyah', 2800),
  ('Al Kamil', 1150),
  ('Adham', 3684),
  ('Bahrah', 1906),
  ('King Abdullah Economic City', 3666),
  ('Madinah', 14),
  ('Yanbu', 483),
  ('Al Ula', 199),
  ('Badr', 1053),
  ('Khaybar', 288),
  ('Mahd adh Dhahab', 360),
  ('Al Hinakiyah', 777),
  ('Buraydah', 11),
  ('Unayzah', 80),
  ('Ar Rass', 2421),
  ('Al Bukayriyah', 2630),
  ('Al Mithnab', 2448),
  ('Riyadh Al Khabra', 2467),
  ('Al Badayea', 2481),
  ('Uyun AlJiwa', 1999),
  ('Dammam', 13),
  ('Al Khobar', 31),
  ('Dhahran', 227),
  ('Jubail', 113),
  ('Al Hofuf', 12),
  ('Al Mubarraz', 2748),
  ('Qatif', 67),
  ('Ras Tanura', 2590),
  ('Abqaiq', 243),
  ('Hafar Al Batin', 47),
  ('Al Khafji', 2464),
  ('An Nairyah', 115),
  ('Safwa', 2167),
  ('Saihat', 454),
  ('Qaryat Al Ulya', 89),
  ('Abha', 15),
  ('Khamis Mushait', 62),
  ('Bisha', 1514),
  ('Mahayil Asir', 1801),
  ('Sarat Abidah', 3328),
  ('An Namas', 2519),
  ('Ahad Rafidah', 65),
  ('Rijal Almaa', 1846),
  ('Tathlith', 1443),
  ('Tabuk', 1),
  ('Duba', 1947),
  ('Umluj', 323),
  ('Haql', 36),
  ('Al Wajh', 233),
  ('Tayma', 74),
  ('Hail', 10),
  ('Baqaa', 2370),
  ('Al Ghazalah', 2715),
  ('Al Shinan', 1228),
  ('Mawqaq', 2351),
  ('Arar', 2213),
  ('Rafha', 2256),
  ('Turaif', 2208),
  ('Al Uwayqilah', 2215),
  ('Jazan', 17),
  ('Sabya', 3479),
  ('Abu Arish', 3525),
  ('Samtah', 3542),
  ('Ahad Al Masarihah', 3652),
  ('Farasan', 3571),
  ('Al Darb', 3402),
  ('Baish', 3462),
  ('Najran', 3417),
  ('Sharurah', 3347),
  ('Habuna', 3396),
  ('Badr Al Janub', 3342),
  ('Yadamah', 2522),
  ('Al Bahah', 1542),
  ('Baljurashi', 1531),
  ('Al Mandaq', 2835),
  ('Al Aqiq', 2819),
  ('Qilwah', 3220),
  ('Sakaka', 2237),
  ('Dumat Al Jandal', 2268),
  ('Qurayyat', 2226),
  ('Tabarjal', 2240)
) AS v(en, ext_id)
WHERE c.external_id IS NULL
  AND EXISTS (SELECT 1 FROM qvm_new_apps.cities_descriptions d
                JOIN qvm_new_apps.languages l ON l.language_id = d.language_id
               WHERE d.city_id = c.city_id AND l.code = 'en' AND lower(btrim(d.name)) = lower(v.en));

------------------------------------------------------------------------------ districts

CREATE TABLE IF NOT EXISTS qvm_new_apps.districts (
  district_id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  city_id     integer NOT NULL REFERENCES qvm_new_apps.cities(city_id) ON DELETE CASCADE,
  -- The dataset's own id, so a district survives a re-import and can be matched against any other
  -- system built on the same reference data.
  external_id bigint,
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  integer NOT NULL DEFAULT 100,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_districts_city ON qvm_new_apps.districts (city_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_districts_external_id ON qvm_new_apps.districts (external_id)
  WHERE external_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS qvm_new_apps.districts_descriptions (
  district_id integer NOT NULL REFERENCES qvm_new_apps.districts(district_id) ON DELETE CASCADE,
  language_id integer NOT NULL REFERENCES qvm_new_apps.languages(language_id),
  name        text    NOT NULL CHECK (btrim(name) <> ''),
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (district_id, language_id)
);

-- Same fallback chain as every other resolved view: the reader's language, then the default, then
-- whatever exists — so a district is never nameless because one translation is missing.
CREATE OR REPLACE VIEW qvm_new_apps.v_districts AS
SELECT d.district_id, d.city_id, d.external_id, d.is_active, d.sort_order,
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

GRANT SELECT ON qvm_new_apps.districts, qvm_new_apps.districts_descriptions TO authenticated;
GRANT ALL ON qvm_new_apps.districts, qvm_new_apps.districts_descriptions TO service_role;
