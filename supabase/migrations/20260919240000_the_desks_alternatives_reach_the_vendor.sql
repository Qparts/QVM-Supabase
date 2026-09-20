-- The desk's alternatives reach the vendor.
--
-- An alternative the desk adds on the Extract PN page names the line, not a vendor. The vendor's
-- pricing pages read alternatives by their line — alternatives_of_cost behind the quotation detail,
-- list_vendor_item_alternatives behind the panel — so the desk's never appeared. Both now also
-- return the desk's alternatives on the same line, labelled by source: the vendor sees them
-- read-only and may price one by adding their own row from it.
CREATE OR REPLACE FUNCTION qvm_new_apps.alternatives_of_cost(p_cost_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alternative_id',      a.alternative_id,
           'source',              a.source,
           'cost_id',             a.cost_id,
           'part_number',         a.part_number,
           'brand_class',         a.brand_class,
           'brand_class_name',    bc.list_data,
           'brand_id',            a.brand_id,
           'brand_name',          br.list_data,
           'origin_country_id',   a.origin_country_id,
           'origin_country_name_en', oc.name_en,
           'origin_country_name_ar', oc.name_ar,
           'unit_price',          a.unit_price,
           'available_quantity',  a.available_quantity,
           'delivery_days',       a.delivery_days,
           'note',                a.note,
           'photos',              a.photos,
           'visible_to_workshop', a.visible_to_workshop,
           'created_at',          a.created_at) ORDER BY (a.source = 'qparts') DESC, a.alternative_id), '[]'::jsonb)
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
   WHERE a.cost_id = p_cost_id
      OR (a.source = 'qparts' AND a.quotation_item_id = (SELECT v.quotation_item_id FROM qvm_new_apps.quotation_vendor_items v WHERE v.cost_id = p_cost_id));
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_item_alternatives(p_cost_ids bigint[], p_token uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alternative_id',      a.alternative_id,
           'source',              a.source,
           'cost_id',             a.cost_id,
           'part_number',         a.part_number,
           'brand_class',         a.brand_class,
           'brand_class_name',    bc.list_data,
           'brand_id',            a.brand_id,
           'brand_name',          br.list_data,
           'origin_country_id',   a.origin_country_id,
           'origin_country_name_en', oc.name_en,
           'origin_country_name_ar', oc.name_ar,
           'unit_price',          a.unit_price,
           'available_quantity',  a.available_quantity,
           'delivery_days',       a.delivery_days,
           'note',                a.note,
           'photos',              a.photos,
           'visible_to_workshop', a.visible_to_workshop,
           'created_at',          a.created_at) ORDER BY (a.source = 'qparts') DESC, a.alternative_id), '[]'::jsonb)
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
   WHERE (
           (a.cost_id = ANY(p_cost_ids) AND qvm_new_apps.can_touch_vendor_cost(a.cost_id, p_token))
        OR (a.source = 'qparts' AND EXISTS (
              SELECT 1 FROM qvm_new_apps.quotation_vendor_items v
               WHERE v.cost_id = ANY(p_cost_ids) AND v.quotation_item_id = a.quotation_item_id
                 AND qvm_new_apps.can_touch_vendor_cost(v.cost_id, p_token)))
         );
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 28 $$;
