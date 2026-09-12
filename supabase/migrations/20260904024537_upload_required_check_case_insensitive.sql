-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The gate now reads the header the same way the parser does.
--
-- The required-column check tested `p_raw->>key` exactly, so a sheet whose header said
-- «id_make» was rejected for a missing ID_make that was sitting right there in the row —
-- a rejection reason that names a column the file appears to contain is the worst kind.
-- It still checks the declared name only, with no fall back to the previous one: a file
-- using the old headers is meant to be turned away.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_clean_row';

  if position('upload_raw_get(p_raw, v_col->>''key'')' in v_def) > 0 then return; end if;

  v_def := replace(v_def,
    'if nullif(btrim(coalesce(p_raw->>(v_col->>''key''), '''')), '''') is null then',
    'if qvm_new_apps.upload_raw_get(p_raw, v_col->>''key'') is null then');

  if position('upload_raw_get(p_raw, v_col->>''key'')' in v_def) = 0 then
    raise exception 'the required-column check was not rewritten';
  end if;
  execute v_def;
end $$;
