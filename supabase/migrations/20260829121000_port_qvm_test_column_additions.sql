-- Column-level additions on tables that already exist on both branches, needed by the
-- Extract-PN v2 feature (quotation_items/quotations lock+state tracking), plus two small
-- unrelated additions (customers.customer_code, quotation_attachments.shared_with_vendor).
-- Same QVM/test -> QVM/dev port; QVM/test untouched.

ALTER TABLE qvm_new_apps."customers" ADD COLUMN IF NOT EXISTS "customer_code" text;
ALTER TABLE qvm_new_apps."quotation_attachments" ADD COLUMN IF NOT EXISTS "shared_with_vendor" boolean DEFAULT false;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "draft_part_number" text;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "pn_state" text DEFAULT 'none'::text;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "pn_saved_by" uuid;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "pn_saved_at" timestamp with time zone;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "extraction_unclear_reason" text;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "extraction_flagged_by" uuid;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "extraction_flagged_at" timestamp with time zone;
ALTER TABLE qvm_new_apps."quotation_items" ADD COLUMN IF NOT EXISTS "added_at_extraction" boolean DEFAULT false;
ALTER TABLE qvm_new_apps."quotations" ADD COLUMN IF NOT EXISTS "extract_locked_by" uuid;
ALTER TABLE qvm_new_apps."quotations" ADD COLUMN IF NOT EXISTS "extract_locked_at" timestamp with time zone;
ALTER TABLE qvm_new_apps."quotations" ADD COLUMN IF NOT EXISTS "extract_lock_touched_at" timestamp with time zone;ALTER TABLE qvm_new_apps.quotation_items ADD CONSTRAINT quotation_items_pn_state_chk CHECK ((pn_state = ANY (ARRAY['none'::text, 'draft'::text, 'saved'::text])));
CREATE UNIQUE INDEX IF NOT EXISTS customers_code_unique ON qvm_new_apps.customers USING btree (upper(btrim(customer_code))) WHERE ((customer_code IS NOT NULL) AND (btrim(customer_code) <> ''::text) AND (merged_into IS NULL));
CREATE INDEX IF NOT EXISTS quotation_items_pn_state_idx ON qvm_new_apps.quotation_items USING btree (pn_state);
CREATE INDEX IF NOT EXISTS quotations_extract_lock_idx ON qvm_new_apps.quotations USING btree (extract_locked_by) WHERE (extract_locked_by IS NOT NULL);
