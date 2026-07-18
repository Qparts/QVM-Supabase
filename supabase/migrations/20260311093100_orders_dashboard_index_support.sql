-- Synced from QVM/test branch applied migration history (version 20260311093100, name: orders_dashboard_index_support)
-- Confirmed items: speed up order-level joins + status filtering
CREATE INDEX IF NOT EXISTS idx_confirmed_items_confirmed_order_id
  ON qvm_new_apps.confirmed_items (confirmed_order_id);

CREATE INDEX IF NOT EXISTS idx_confirmed_items_confirmed_order_id_item_status
  ON qvm_new_apps.confirmed_items (confirmed_order_id, item_status);

-- Optional: speed up quotation join from confirmed_orders
CREATE INDEX IF NOT EXISTS idx_confirmed_orders_quotation_id
  ON qvm_new_apps.confirmed_orders (quotation_id);
;
