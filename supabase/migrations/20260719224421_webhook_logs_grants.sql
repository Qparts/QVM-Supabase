-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

GRANT INSERT, SELECT ON qvm_new_apps.webhook_logs TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.webhook_logs_id_seq TO service_role;
