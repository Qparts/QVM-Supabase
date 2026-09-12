-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  -- The catalog has no batch: a part is built up from every file that mentions it, so it
  -- carries `source` instead. Same question, answered from the column that holds the answer.
  v_old text := '                 ''updated_at'', c.updated_at) as x,';
begin
  if position(v_old in v_def) = 0 then raise exception 'catalog updated_at line not found'; end if;
  execute replace(v_def, v_old,
    '                 ''updated_at'', c.updated_at,
                 ''entry_source'', case when c.source = ''manual'' then ''manual'' else ''file'' end,
                 ''entry_file'', null) as x,');
end
$mig$;
