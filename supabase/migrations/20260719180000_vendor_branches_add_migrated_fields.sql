-- Step 1/4 of moving branch-specific fields from vendors to vendor_branches.
-- Adds the columns only; no data moved yet (see the following backfill migration).
-- vendor_branches.brands already exists (added in vendor_branches_and_roles_phase1) and is
-- reused as-is; not re-added here.

ALTER TABLE qvm_new_apps.vendor_branches
  ADD COLUMN IF NOT EXISTS region jsonb,
  ADD COLUMN IF NOT EXISTS operating_hours jsonb,
  ADD COLUMN IF NOT EXISTS items_type jsonb,
  ADD COLUMN IF NOT EXISTS payment_method text,
  ADD COLUMN IF NOT EXISTS bank_name text,
  ADD COLUMN IF NOT EXISTS bank_account text,
  ADD COLUMN IF NOT EXISTS alternative_account text,
  ADD COLUMN IF NOT EXISTS bank_accounts jsonb,
  ADD COLUMN IF NOT EXISTS bank_account_name text,
  ADD COLUMN IF NOT EXISTS bank_iban text,
  ADD COLUMN IF NOT EXISTS bank_and_cr_files text,
  ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS discount_percent double precision,
  ADD COLUMN IF NOT EXISTS notify_by_email boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS notify_by_whatsapp boolean NOT NULL DEFAULT false;

-- Mirrors the filtering usage in list_vendor_filters / get_vendors_dashboard, now moving
-- to query vendor_branches instead of vendors.
CREATE INDEX IF NOT EXISTS idx_vendor_branches_region ON qvm_new_apps.vendor_branches USING gin (region);
CREATE INDEX IF NOT EXISTS idx_vendor_branches_payment_method ON qvm_new_apps.vendor_branches (payment_method);
