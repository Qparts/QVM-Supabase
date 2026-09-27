-- Alternatives hang under the part they were offered for.
--
-- The previous file made the relation symmetric, so an alternative also listed the line's part
-- as its own alternative. That is not what the catalogue should say: the main item is the part
-- on the quotation line, and its alternatives are the numbers vendors (or Qparts) offered
-- instead of it. A part that was only ever offered as an alternative has none of its own.
-- This restores that one-way reading; the view is otherwise the 20260927150000 definition.

DROP VIEW IF EXISTS qvm_new_apps.part_alternatives_v;
CREATE VIEW qvm_new_apps.part_alternatives_v AS
  SELECT CASE WHEN a.source = 'qparts' THEN 'qparts' ELSE 'vendor' END::text AS origin,
         a.alternative_id AS source_id,
         qvm_new_apps.normalize_part_number(qi.part_number) AS clean_part_number,
         qvm_new_apps.normalize_part_number(a.part_number) AS alt_part_number,
         a.part_number AS raw_alt_part_number,
         CASE WHEN a.source = 'qparts' THEN 'بديل من كيوبارتس' ELSE 'بديل من المورد' END::text AS origin_label,
         CASE WHEN a.source = 'qparts' THEN 'Qparts' ELSE v.vendor_name END::text AS offered_by,
         bc.list_data AS brand_class, br.list_data AS brand, oc.name_ar AS country,
         a.unit_price, a.available_quantity, a.delivery_days,
         a.note, q.order_number, NULL::bigint AS batch_id, a.created_at,
         -- the part the alternative was offered for, as its own line describes it
         pm.list_data AS parent_make, pc.list_data AS parent_class,
         -- بلد المنشأ of the part: what the extractor set on the line when it did, else what the
         -- vendor stated on the priced line the alternative was offered against.
         COALESCE(po.name_ar, pvo.name_ar) AS parent_country
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = a.cost_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = COALESCE(a.quotation_item_id, qvi.quotation_item_id)
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
    LEFT JOIN qvm_new_apps.list_data pm ON pm.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data pc ON pc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.origin_countries po ON po.origin_country_id = qi.origin_country_id
    LEFT JOIN qvm_new_apps.origin_countries pvo ON pvo.origin_country_id = qvi.origin_country_id
   WHERE COALESCE(btrim(a.part_number), '') <> ''
     AND COALESCE(qvm_new_apps.normalize_part_number(qi.part_number), '') <> '';
GRANT SELECT ON qvm_new_apps.part_alternatives_v TO service_role;
