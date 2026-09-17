-- «Other» is a model, not a make.
--
-- The models sheet carried a brand called Other, and 20260919102100 added it to car_brand along with
-- the other brands list_data lacked. That put "Other" in the Vehicle Brand dropdown, which is not
-- what anyone means by a brand. It goes; and instead every brand's model list ends with an Other —
-- the entry that opens the quick-add for a model the list does not have yet.

-- The Other brand and whatever hung off it. Both rows were created by the previous migration; a
-- quotation raised against them in the minutes between is not something this deletes — the join
-- refuses a brand any quotation item names.
DELETE FROM qvm_new_apps.vehicle_models m
 USING qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id AND l.list_name = 'car_brand'
 WHERE m.brand_id = ld.list_data_id
   AND lower(btrim(ld.list_data)) = 'other'
   AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi WHERE qi.main_brand = ld.list_data_id);

DELETE FROM qvm_new_apps.list_data ld
 USING qvm_new_apps.lists l
 WHERE l.list_id = ld.list_id AND l.list_name = 'car_brand'
   AND lower(btrim(ld.list_data)) = 'other'
   AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi WHERE qi.main_brand = ld.list_data_id)
   AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.vehicle_models m WHERE m.brand_id = ld.list_data_id);

-- Every brand gets an Other.
INSERT INTO qvm_new_apps.vehicle_models (brand_id, name_en, name_ar)
SELECT ld.list_data_id, 'Other', 'أخرى'
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id AND l.list_name = 'car_brand'
ON CONFLICT (brand_id, lower(name_en)) DO UPDATE SET name_ar = COALESCE(qvm_new_apps.vehicle_models.name_ar, EXCLUDED.name_ar), is_active = true;

-- Other sorts last, whatever the alphabet says.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_vehicle_models(p_brand_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'model_id', m.model_id, 'brand_id', m.brand_id, 'name_en', m.name_en, 'name_ar', m.name_ar)
           ORDER BY (lower(m.name_en) = 'other'), m.name_en), '[]'::jsonb)
    FROM qvm_new_apps.vehicle_models m
   WHERE m.brand_id = p_brand_id AND m.is_active;
$function$;
