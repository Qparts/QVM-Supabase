-- Step 4/4 of moving branch-specific fields from vendors to vendor_branches.
-- Drops the now-unused columns from vendors. Applied last, only after the RPC migration
-- (20260719200000) confirms nothing reads/writes these columns on vendors anymore.

ALTER TABLE qvm_new_apps.vendors
  DROP COLUMN IF EXISTS region,
  DROP COLUMN IF EXISTS operating_hours,
  DROP COLUMN IF EXISTS brands,
  DROP COLUMN IF EXISTS items_type,
  DROP COLUMN IF EXISTS payment_method,
  DROP COLUMN IF EXISTS bank_name,
  DROP COLUMN IF EXISTS bank_account,
  DROP COLUMN IF EXISTS alternative_account,
  DROP COLUMN IF EXISTS bank_accounts,
  DROP COLUMN IF EXISTS bank_and_cr_files,
  DROP COLUMN IF EXISTS location,
  DROP COLUMN IF EXISTS discount_percent,
  DROP COLUMN IF EXISTS notify_by_email,
  DROP COLUMN IF EXISTS notify_by_whatsapp;
