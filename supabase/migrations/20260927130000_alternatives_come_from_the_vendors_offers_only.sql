-- Alternatives come from the vendors' offers only.
--
-- The first cut of part_alternatives_v also read the aliases files and the alternative number a
-- buyer types on an order line. Neither is an alternative in the sense the team means: an
-- alias is the same part under another number, and the line's field is a note to the buyer.
-- What counts is what a vendor (or the buying desk on a vendor's behalf) actually offered
-- instead, with a price — quotation_vendor_item_alternatives, and nothing else. That is also why
-- the price under a catalogue part looked empty: the rows without one were the aliases.

-- Dropped and recreated: the price column's declared type changes, which REPLACE refuses.
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
         a.note, q.order_number, NULL::bigint AS batch_id, a.created_at
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = a.cost_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = COALESCE(a.quotation_item_id, qvi.quotation_item_id)
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
   WHERE COALESCE(btrim(a.part_number), '') <> ''
     AND COALESCE(qvm_new_apps.normalize_part_number(qi.part_number), '') <> '';

GRANT SELECT ON qvm_new_apps.part_alternatives_v TO service_role;
