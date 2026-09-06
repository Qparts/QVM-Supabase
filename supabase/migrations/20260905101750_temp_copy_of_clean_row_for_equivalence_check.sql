-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_clean_row(jsonb,text,text,bigint)'::regprocedure);
begin
  -- A throwaway snapshot of the importer as it stands, so the refactor can be shown to
  -- produce identical output before the real one is replaced. Dropped in the next migration.
  execute replace(v_def,
    'CREATE OR REPLACE FUNCTION qvm_new_apps.upload_clean_row(',
    'CREATE OR REPLACE FUNCTION qvm_new_apps.zz_clean_row_prev(');
end
$mig$;
