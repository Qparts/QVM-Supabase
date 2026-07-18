-- Synced from QVM/test branch applied migration history (version 20260324113934, name: qpd351_delivery_items_unique_index)
-- QPD-351: Ensure upsert works on delivery_items by adding unique constraint on (delivery_id, confirmed_item_id)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE c.conname = 'delivery_items_delivery_confirmeditem_uniq'
      AND n.nspname = 'qvm_new_apps'
  ) THEN
    ALTER TABLE qvm_new_apps.delivery_items
      ADD CONSTRAINT delivery_items_delivery_confirmeditem_uniq UNIQUE (delivery_id, confirmed_item_id);
  END IF;
END $$;

-- Helpful indexes for lookups
CREATE INDEX IF NOT EXISTS deliveries_confirmed_order_id_idx ON qvm_new_apps.deliveries(confirmed_order_id);
CREATE INDEX IF NOT EXISTS confirmed_items_confirmed_order_id_idx ON qvm_new_apps.confirmed_items(confirmed_order_id);
CREATE INDEX IF NOT EXISTS delivery_items_delivery_id_idx ON qvm_new_apps.delivery_items(delivery_id);
;
