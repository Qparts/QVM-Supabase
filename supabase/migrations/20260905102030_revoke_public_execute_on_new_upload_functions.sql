-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Postgres grants EXECUTE to PUBLIC on every new function and every role inherits PUBLIC,
-- including the bridge login on the VPS. Same treatment the rest of this schema already got.
revoke all on function qvm_new_apps.upload_clean_part_number(text, text, text, bigint) from public;
grant execute on function qvm_new_apps.upload_clean_part_number(text, text, text, bigint) to authenticated, service_role;

revoke all on function qvm_new_apps.upload_template_record_kind(text) from public;
grant execute on function qvm_new_apps.upload_template_record_kind(text) to authenticated, service_role;
