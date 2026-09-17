-- A priced offer states its quantity.
--
-- The vendor dashboard showed the requested quantity on every line and saved it only when the
-- vendor typed over it, so an offer the vendor priced at the shown quantity carried NULL and the
-- buyer read "—". The dashboard now saves what it shows; this fills the rows priced before it did,
-- with the quantity the vendor was looking at when they priced.
UPDATE qvm_new_apps.quotation_vendor_items qvi
   SET available_quantity = qi.quantity, updated_at = now()
  FROM qvm_new_apps.quotation_items qi
 WHERE qi.quotation_item_id = qvi.quotation_item_id
   AND qvi.available_quantity IS NULL
   AND qvi.cost IS NOT NULL AND qvi.cost > 0
   AND qi.quantity IS NOT NULL;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 14 $$;
