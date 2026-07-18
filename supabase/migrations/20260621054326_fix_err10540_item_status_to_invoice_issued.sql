-- Synced from QVM/test branch applied migration history (version 20260621054326, name: fix_err10540_item_status_to_invoice_issued)
-- Fix ERR10540: items have invoice_number set but item_status is still 'Delivered' (23)
-- Update to Invoice Issued (26) so they appear in the archive
UPDATE qvm_new_apps.confirmed_items
SET item_status = 26
WHERE confirmed_item_id IN (31380, 31381)
  AND item_status = 23;

-- Log the status change
INSERT INTO qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by)
VALUES
  (31380, 26, NULL),
  (31381, 26, NULL);;
