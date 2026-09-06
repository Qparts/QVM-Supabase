-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_clean_row(jsonb,text,text,bigint)'::regprocedure);
  v_old text := '     and coalesce(r.source_id, -1) = coalesce(p_source_id, -1)';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'source_id line not found';
  end if;
  execute replace(v_def, v_old, v_old || E'\n' ||
    '     -- A rule belongs to one records tab. An older rule has no tab and still applies to' || E'\n' ||
    '     -- every file, which is what it meant when it was written.' || E'\n' ||
    '     and (r.record_kind is null' || E'\n' ||
    '          or r.record_kind = qvm_new_apps.upload_template_record_kind(p_template_key))');
end
$mig$;
