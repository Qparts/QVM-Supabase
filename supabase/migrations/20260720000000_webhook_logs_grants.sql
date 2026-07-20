-- RLS alone doesn't grant base table privileges in this project (tables are explicitly GRANTed
-- per-role, not left to default privileges) — without this, service_role's insert into
-- webhook_logs fails with "permission denied for table webhook_logs" even though service_role
-- bypasses RLS. Discovered when send_rfq_webhook's log writes were silently failing.
GRANT INSERT, SELECT ON qvm_new_apps.webhook_logs TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.webhook_logs_id_seq TO service_role;
