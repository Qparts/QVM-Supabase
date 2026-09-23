-- line_item_code carries no constraint.
--
-- The legacy ORDER_NUMBER-N label is written for history only; nothing reads it, and the
-- per-quotation lock added in 20260923100000 already keeps the numbering orderly. The unique
-- constraint was the last thing that could still reject an insert over it, so it goes. The
-- column stays nullable, unindexed and unconstrained.

ALTER TABLE qvm_new_apps.quotation_items
  DROP CONSTRAINT IF EXISTS quotation_items_line_item_code_key;

DROP INDEX IF EXISTS qvm_new_apps.quotation_items_line_item_code_key;
DROP INDEX IF EXISTS qvm_new_apps.quotation_items_line_item_code_uk;
