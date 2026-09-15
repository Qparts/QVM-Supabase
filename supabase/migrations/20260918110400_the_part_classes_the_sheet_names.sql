-- The part classes, named the way the team's sheet names them.
--
-- The previous migration guessed at this and guessed wrong. It went looking for a brand_class row
-- called "Commercial" to rename; there has never been one. Reading the live list settled it:
--
--   107 Genuine   108 OEM   109 Aftermarket   110 Used   111 Any
--
-- "Aftermarket" IS تجاري. So the rename matched nothing, no existing row moved, and the only thing
-- the guess left behind was a stray "Commercial Grade 2" — renamed here rather than deleted, since
-- it is the row the second grade was always meant to be.
--
-- The sheet asks for seven classes: أصلي، OEM، تجاري، تجاري درجة أولى، تجاري درجة ثانية، مستعمل،
-- مجدّد. تجاري stays alongside its two grades because the sheet lists it and because quotation
-- items already point at 109 — dropping it would strand them on a class the picker no longer
-- offers, with nothing in the data to say which grade was meant. "Any" (111) is not in the sheet
-- and is left alone: it is a request-side answer ("any type will do"), not a grade a vendor offers.

UPDATE qvm_new_apps.list_data ld
   SET list_data = 'Aftermarket Grade B'
  FROM qvm_new_apps.lists l
 WHERE l.list_id = ld.list_id
   AND l.list_name = 'brand_class'
   AND lower(btrim(ld.list_data)) IN ('commercial grade 2', 'commercial grade 1');

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT l.list_id, v.name
  FROM qvm_new_apps.lists l
  CROSS JOIN (VALUES ('Aftermarket Grade A'), ('Remanufactured')) AS v(name)
 WHERE l.list_name = 'brand_class'
   AND NOT EXISTS (
     SELECT 1 FROM qvm_new_apps.list_data ld
      WHERE ld.list_id = l.list_id
        AND lower(btrim(ld.list_data)) = lower(v.name));

-- Ordered by what the grades mean, not by when each row happened to be inserted. Without this the
-- picker reads Genuine, OEM, Aftermarket, Used, Any, Grade B, Grade A — the two grades separated
-- from the class they grade, in the wrong order, because Grade B was created first.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_brand_classes()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'brand_class_id', ld.list_data_id,
           'brand_class_name', ld.list_data)
         ORDER BY CASE lower(btrim(ld.list_data))
                    WHEN 'genuine'             THEN 1
                    WHEN 'oem'                 THEN 2
                    WHEN 'aftermarket'         THEN 3
                    WHEN 'aftermarket grade a' THEN 4
                    WHEN 'aftermarket grade b' THEN 5
                    WHEN 'used'                THEN 6
                    WHEN 'remanufactured'      THEN 7
                    ELSE 99
                  END, ld.list_data_id), '[]'::jsonb)
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
   WHERE l.list_name = 'brand_class';
$function$;
