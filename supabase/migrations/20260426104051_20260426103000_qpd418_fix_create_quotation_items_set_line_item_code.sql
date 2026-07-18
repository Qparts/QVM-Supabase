-- Synced from QVM/test branch applied migration history (version 20260426104051, name: 20260426103000_qpd418_fix_create_quotation_items_set_line_item_code)
BEGIN;

-- QPD-418: Ensure create_quotation_items sets line_item_code per quotation using order_number and next index
CREATE OR REPLACE FUNCTION public.create_quotation_items(p_items jsonb)
RETURNS SETOF qvm_new_apps.quotation_items
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH input AS (
    SELECT
      (item->>'quotation_id')::integer AS quotation_id,
      (item->>'customer_id')::bigint AS customer_id,
      nullif(item->>'vin','null')::text AS vin,
      (item->'main_brand')::integer AS main_brand,
      nullif(item->>'model','null')::text AS model,
      nullif(item->>'part_number','null')::text AS part_number,
      nullif(item->>'part_description','null')::text AS part_description,
      (item->>'quantity')::integer AS quantity,
      (item->'brand_class')::integer AS brand_class,
      nullif(item->>'part_photo','null')::text AS part_photo,
      (item->>'item_status')::integer AS item_status,
      nullif(item->>'estimated_price','null')::numeric AS estimated_price
    FROM jsonb_array_elements(p_items) AS item
  ),
  existing_max AS (
    SELECT
      qi.quotation_id,
      COALESCE(MAX(NULLIF(regexp_replace(COALESCE(qi.line_item_code, ''), '^.*-(\\d+)$', '\\1'), '')::int), 0) AS max_index
    FROM qvm_new_apps.quotation_items qi
    GROUP BY qi.quotation_id
  ),
  numbered AS (
    SELECT
      i.*,
      q.order_number,
      COALESCE(em.max_index, 0) AS base_index,
      ROW_NUMBER() OVER (PARTITION BY i.quotation_id ORDER BY i.quotation_id) AS rn
    FROM input i
    JOIN qvm_new_apps.quotations q ON q.quotation_id = i.quotation_id
    LEFT JOIN existing_max em ON em.quotation_id = i.quotation_id
  )
  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    customer_id,
    vin,
    main_brand,
    model,
    part_number,
    part_description,
    quantity,
    brand_class,
    part_photo,
    item_status,
    estimated_price,
    line_item_code
  )
  SELECT
    n.quotation_id,
    n.customer_id,
    n.vin,
    n.main_brand,
    n.model,
    n.part_number,
    n.part_description,
    n.quantity,
    n.brand_class,
    n.part_photo,
    n.item_status,
    n.estimated_price,
    n.order_number || '-' || (n.base_index + n.rn)::text
  FROM numbered n
  RETURNING *;
END;
$$;

COMMIT;
;
