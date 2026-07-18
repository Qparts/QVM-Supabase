-- Synced from QVM/test branch applied migration history (version 20260624012929, name: fix_existing_delivery_notes_totals)

-- Fix existing delivery_notes: backfill discount_percent, shipping_price, and recalculate totals
UPDATE qvm_new_apps.delivery_notes dn
SET
  discount_percent = coalesce(qi.discount_percent, 0),
  shipping_price   = coalesce(q.shipping_price, 0),
  total_price_before_vat = round(
    (coalesce(dn.price_before_vat, 0) * coalesce(dn.approved_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0))::numeric, 2
  ),
  vat = round(
    (coalesce(dn.price_before_vat, 0) * coalesce(dn.approved_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 0.15)::numeric, 2
  ),
  total_price_including_vat = round(
    (coalesce(dn.price_before_vat, 0) * coalesce(dn.approved_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 1.15)::numeric, 2
  ),
  updated_at = now()
FROM qvm_new_apps.confirmed_items ci
JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
WHERE dn.confirmed_item_id = ci.confirmed_item_id;

-- Fix existing return_notes similarly
UPDATE qvm_new_apps.return_notes rn
SET
  discount_percent = coalesce(qi.discount_percent, 0),
  shipping_price   = coalesce(q.shipping_price, 0),
  total_price_before_vat = round(
    (coalesce(rn.price_before_vat, 0) * coalesce(rn.return_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0))::numeric, 2
  ),
  vat = round(
    (coalesce(rn.price_before_vat, 0) * coalesce(rn.return_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 0.15)::numeric, 2
  ),
  total_price_including_vat = round(
    (coalesce(rn.price_before_vat, 0) * coalesce(rn.return_quantity, 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 1.15)::numeric, 2
  ),
  updated_at = now()
FROM qvm_new_apps.confirmed_items ci
JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
WHERE rn.confirmed_item_id = ci.confirmed_item_id;
;
