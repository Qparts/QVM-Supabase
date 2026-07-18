-- Synced from QVM/test branch applied migration history (version 20260621051015, name: backfill_delivery_notes_vat_totals)
-- Backfill vat and total_price_including_vat for rows that have price_before_vat but null totals
UPDATE qvm_new_apps.delivery_notes
SET
  vat = ROUND((price_before_vat * 0.15)::numeric, 2),
  total_price_including_vat = ROUND((price_before_vat * 1.15)::numeric, 2),
  updated_at = now()
WHERE
  total_price_including_vat IS NULL
  AND price_before_vat IS NOT NULL
  AND price_before_vat > 0;;
