-- Synced from QVM/test branch applied migration history (version 20260621054405, name: backfill_invoice_issued_status_for_new_invoices)
-- Backfill: any delivery_notes row with an INV- invoice_number
-- whose confirmed_item's status is not already Invoice Issued (26) or Settled (31)
-- should be updated to Invoice Issued (26) so they appear in the archive

UPDATE qvm_new_apps.confirmed_items ci
SET item_status = 26
FROM qvm_new_apps.delivery_notes dn
WHERE dn.confirmed_item_id = ci.confirmed_item_id
  AND dn.invoice_number LIKE 'INV-%'
  AND ci.item_status NOT IN (26, 31);

-- Also update delivery_notes.status column to match
UPDATE qvm_new_apps.delivery_notes
SET status = 'Invoice Issued'
WHERE invoice_number LIKE 'INV-%'
  AND (status IS NULL OR status <> 'Invoice Issued');;
