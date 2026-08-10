-- QNEW-100 Phase 1: the one admin-toggleable switch for away-from-app delivery of unseen activity —
-- browser_push only (never email/WhatsApp, per the ticket: an in-app-style nudge, not a formal
-- message). recipient_type/recipient_role_id aren't used for recipient resolution here (the owner
-- is already resolved from activity_log.owner_user_id by dispatch_record_activity_push) — this row
-- is really just the on/off + channel switch, editable from the same Notification Rules page.
INSERT INTO qvm_new_apps.notification_rules (trigger_type, recipient_type, message_template, channels)
VALUES ('record_activity', 'internal_role', 'You have unseen activity on a record you own.', ARRAY['browser_push']);
