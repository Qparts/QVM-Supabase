-- Step 2/4 of moving branch-specific fields from vendors to vendor_branches.
-- Backfills the new vendor_branches columns from each vendor's current values.
--
-- 54 of 55 vendors currently have zero vendor_branches rows, so a default branch is created
-- for each of those first. The 1 vendor that already has a branch gets its existing branch
-- backfilled instead (without clobbering that branch's already-customized brands).

-- 1) Create a default branch for every vendor with no branch at all, carrying over its
--    current field values. city has no direct source on vendors, so it's derived from the
--    vendor's first region entry (regions are city/area names per list_vendor_filters).
INSERT INTO qvm_new_apps.vendor_branches (
  vendor_id, branch_name, city, brands, region, operating_hours, items_type,
  payment_method, bank_name, bank_account, alternative_account, bank_accounts,
  bank_and_cr_files, location, discount_percent, notify_by_email, notify_by_whatsapp,
  is_active
)
SELECT
  v.vendor_id,
  'الفرع الرئيسي',
  COALESCE(NULLIF(btrim(v.region->>0), ''), 'Unknown'),
  COALESCE(v.brands, '[]'::jsonb),
  v.region,
  v.operating_hours,
  v.items_type,
  v.payment_method,
  v.bank_name,
  v.bank_account,
  v.alternative_account,
  v.bank_accounts,
  v.bank_and_cr_files,
  v.location,
  v.discount_percent,
  v.notify_by_email,
  v.notify_by_whatsapp,
  true
FROM qvm_new_apps.vendors v
WHERE NOT EXISTS (
  SELECT 1 FROM qvm_new_apps.vendor_branches vb WHERE vb.vendor_id = v.vendor_id
);

-- 2) Backfill vendors that already had at least one branch. brands is only overwritten if
--    still the untouched default ('[]'), so a branch that's already been given real brand
--    data (there's exactly one such branch today) is left alone.
UPDATE qvm_new_apps.vendor_branches vb
SET region = v.region,
    operating_hours = v.operating_hours,
    brands = CASE WHEN vb.brands = '[]'::jsonb THEN v.brands ELSE vb.brands END,
    items_type = v.items_type,
    payment_method = v.payment_method,
    bank_name = v.bank_name,
    bank_account = v.bank_account,
    alternative_account = v.alternative_account,
    bank_accounts = v.bank_accounts,
    bank_and_cr_files = v.bank_and_cr_files,
    location = v.location,
    discount_percent = v.discount_percent,
    notify_by_email = v.notify_by_email,
    notify_by_whatsapp = v.notify_by_whatsapp,
    updated_at = now()
FROM qvm_new_apps.vendors v
WHERE vb.vendor_id = v.vendor_id
  AND vb.region IS NULL AND vb.operating_hours IS NULL AND vb.payment_method IS NULL;

-- 3) Every vendor needs a resolvable preferred branch (used by get_vendors_dashboard and
--    get_vendor_notification_channels going forward). Point it at the earliest branch where
--    unset; do not touch vendors that already picked a preferred branch explicitly.
UPDATE qvm_new_apps.vendors v
SET preferred_branch_id = (
  SELECT vb.vendor_branch_id
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = v.vendor_id
  ORDER BY vb.vendor_branch_id ASC
  LIMIT 1
)
WHERE v.preferred_branch_id IS NULL;

-- Verification (informational, not enforced): every vendor should now have a preferred
-- branch. Expect 0 rows:
--   SELECT vendor_id FROM qvm_new_apps.vendors WHERE preferred_branch_id IS NULL;
