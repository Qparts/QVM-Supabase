-- Synced from QVM/test branch applied migration history (version 20260707125651, name: drop_stale_get_vendor_emails_overload)
DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_emails(p_vendor_ids integer[]);;
