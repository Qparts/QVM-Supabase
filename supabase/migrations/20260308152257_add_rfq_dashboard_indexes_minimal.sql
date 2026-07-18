-- Synced from QVM/test branch applied migration history (version 20260308152257, name: add_rfq_dashboard_indexes_minimal)
CREATE INDEX IF NOT EXISTS idx_notes_type_id_internal
  ON qvm_new_apps.notes (note_type, type_id, is_internal);

CREATE INDEX IF NOT EXISTS idx_quotation_items_quotation_id
  ON qvm_new_apps.quotation_items (quotation_id);

CREATE INDEX IF NOT EXISTS idx_quotation_items_quotation_id_item_status
  ON qvm_new_apps.quotation_items (quotation_id, item_status);

CREATE INDEX IF NOT EXISTS idx_quotation_items_customer_id
  ON qvm_new_apps.quotation_items (customer_id);

CREATE INDEX IF NOT EXISTS idx_client_branches_list_data_customer
  ON qvm_new_apps.client_branches (list_data_id, customer_id);

CREATE INDEX IF NOT EXISTS idx_quotations_created_at
  ON qvm_new_apps.quotations (created_at);

CREATE INDEX IF NOT EXISTS idx_quotations_service_advisor
  ON qvm_new_apps.quotations (service_advisor);
;
