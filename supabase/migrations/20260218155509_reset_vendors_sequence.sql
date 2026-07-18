-- Synced from QVM/test branch applied migration history (version 20260218155509, name: reset_vendors_sequence)
-- Reset the vendor_id sequence to match the max vendor_id
SELECT setval(
    'qvm_new_apps.vendors_vendor_id_seq',
    (SELECT COALESCE(MAX(vendor_id), 0) FROM qvm_new_apps.vendors)
);;
