-- QNEW-100 uncovered a real gap in the QNEW-99 FCM schema: notifications.created_by was NOT NULL,
-- assuming every push always originates from a logged-in staff member (the admin composer, or a
-- trigger firing inside an authenticated transaction). QNEW-100's dispatch_record_activity_push
-- can legitimately fire with no real actor at all — e.g. a vendor pricing an item through the
-- magic-link flow (save_vendor_quotation_by_token), which runs anonymously with no Supabase
-- session, so auth.uid() is NULL throughout. Without this, dispatch_push_to_user's INSERT threw,
-- and — because the calling trigger's BEGIN/EXCEPTION block creates an implicit savepoint —
-- silently rolled back the ENTIRE log_activity() call, including the activity_log row itself, so
-- the owner never even got the in-app badge, let alone the push.
ALTER TABLE qvm_new_apps.notifications ALTER COLUMN created_by DROP NOT NULL;
