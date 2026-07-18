-- Synced from QVM/test branch applied migration history (version 20260624011435, name: add_discount_to_delivery_return_notes)

ALTER TABLE qvm_new_apps.delivery_notes ADD COLUMN IF NOT EXISTS discount_percent numeric DEFAULT 0;
ALTER TABLE qvm_new_apps.return_notes ADD COLUMN IF NOT EXISTS discount_percent numeric DEFAULT 0;
;
