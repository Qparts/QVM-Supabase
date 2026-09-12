-- City names repeat, so the index that said otherwise has to go.
--
-- The import of the full city list stopped here:
--
--   duplicate key value violates unique constraint "uq_city_name_per_region_language"
--   Key (language_id, lower(name))=(1, qurayyah) already exists.
--
-- That index is mine, from September, and it is wrong twice over. Its name and the comment above it
-- say the name is held unique "within its region" — but cities_descriptions has no region column,
-- so what it actually enforced was uniqueness across the whole country. And the weaker rule it
-- meant to express is false as well: in the reference data 634 English names repeat nationally and
-- 218 repeat inside a single region. Qurayyah appears twice in one region; so do Umm Al Hamam,
-- Masadah and Al Wuday.
--
-- Two villages sharing a name is not a data error to be prevented, it is the country. What tells
-- them apart is where they are, which is why cities carry coordinates. The index becomes a plain
-- one: it was doing useful work as a lookup path, and none as a constraint.
--
-- It held for a fortnight because 110 hand-picked cities happened not to collide. A guard that only
-- passes on curated data is not a guard.

DROP INDEX IF EXISTS qvm_new_apps.uq_city_name_per_region_language;

CREATE INDEX IF NOT EXISTS idx_city_name_per_language
  ON qvm_new_apps.cities_descriptions (language_id, lower(name));
