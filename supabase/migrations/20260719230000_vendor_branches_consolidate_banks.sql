-- Yesterday's field migration left vendor_branches with 7 separate single-value bank columns
-- (bank_name, bank_account, alternative_account, bank_accounts, bank_account_name, bank_iban,
-- bank_and_cr_files), none of which support more than one bank per branch. Consolidating into
-- one jsonb array holding entries shaped:
--   { bank_name, bank_account_name, bank_iban, bank_and_cr_files: [{url}, ...] }
-- The only existing data (2 vendors' placeholder rows) is all blank strings, so nothing real
-- is lost.

ALTER TABLE qvm_new_apps.vendor_branches
  DROP COLUMN IF EXISTS bank_name,
  DROP COLUMN IF EXISTS bank_account,
  DROP COLUMN IF EXISTS alternative_account,
  DROP COLUMN IF EXISTS bank_accounts,
  DROP COLUMN IF EXISTS bank_account_name,
  DROP COLUMN IF EXISTS bank_iban,
  DROP COLUMN IF EXISTS bank_and_cr_files,
  ADD COLUMN IF NOT EXISTS banks jsonb NOT NULL DEFAULT '[]';
