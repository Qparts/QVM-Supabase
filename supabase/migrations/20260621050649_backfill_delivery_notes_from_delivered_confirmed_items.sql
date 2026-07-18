-- Synced from QVM/test branch applied migration history (version 20260621050649, name: backfill_delivery_notes_from_delivered_confirmed_items)
-- Backfill delivery_notes for all confirmed items with "Delivered" status (id=23)
-- that don't already have a delivery_notes row
INSERT INTO qvm_new_apps.delivery_notes (
  order_number,
  client_name,
  branch,
  confirmation_date,
  delivery_date,
  final_part_number,
  part_description,
  main_brand,
  model,
  brand_class,
  vin,
  plate_number,
  approved_quantity,
  price_before_vat,
  total_price_before_vat,
  vat,
  total_price_including_vat,
  confirmed_item_id,
  created_at,
  updated_at
)
SELECT
  q.order_number,
  COALESCE(ld_client.list_data, ''),
  COALESCE(cb.branch_name, ''),
  co.created_at,
  COALESCE(d.created_at::date, co.created_at::date, now()::date),
  COALESCE(ci.final_part_number, qi.part_number, qi.alternative_part_number, ''),
  COALESCE(qi.part_description, ''),
  COALESCE(ld_brand.list_data, ''),
  COALESCE(qi.model, ''),
  COALESCE(ld_bc.list_data, ''),
  COALESCE(qi.vin, ''),
  COALESCE(q.plate_number, ''),
  GREATEST(COALESCE(ci.approved_qty, qi.quantity, 1), 1),
  COALESCE(qi.price_before_vat, 0),
  COALESCE(qi.total_price_before_vat, 0),
  NULL,
  NULL,
  ci.confirmed_item_id,
  now(),
  now()
FROM qvm_new_apps.confirmed_items ci
JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
LEFT JOIN qvm_new_apps.deliveries d ON d.confirmed_order_id = ci.confirmed_order_id
WHERE ci.item_status = 23  -- Delivered
  AND ci.confirmed_item_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.delivery_notes dn 
    WHERE dn.confirmed_item_id = ci.confirmed_item_id
  )
ON CONFLICT (confirmed_item_id) DO NOTHING;;
