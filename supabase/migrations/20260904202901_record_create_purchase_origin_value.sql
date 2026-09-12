-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.uploaded_record_create(text,jsonb)'::regprocedure);
  v_old text := '            v_branch, ''manual'')';
begin
  if position(v_old in v_def) = 0 then raise exception 'purchases origin line not found'; end if;
  execute replace(v_def, v_old, '            v_branch, ''manual_entry'')');
end
$mig$;
