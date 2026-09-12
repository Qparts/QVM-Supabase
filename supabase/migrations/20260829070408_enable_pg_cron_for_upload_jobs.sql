-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The test environment needs the same scheduled worker production has, or a queued reprocess sits
-- in upload_jobs forever and the screen waits on a job nobody will ever pick up. Additive only:
-- creating the extension and adding one schedule, nothing existing is touched.
create extension if not exists pg_cron;
