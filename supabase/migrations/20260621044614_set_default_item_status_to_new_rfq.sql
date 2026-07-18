-- Synced from QVM/test branch applied migration history (version 20260621044614, name: set_default_item_status_to_new_rfq)
-- Set default item_status to 15 (New RFQ) for new quotation_items
ALTER TABLE qvm_new_apps.quotation_items 
  ALTER COLUMN item_status SET DEFAULT 15;

-- Backfill existing NULL statuses to 15 (New RFQ)
UPDATE qvm_new_apps.quotation_items 
SET item_status = 15 
WHERE item_status IS NULL;;
