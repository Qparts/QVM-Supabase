-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_clean_row(jsonb,text,text,bigint)'::regprocedure);
  v_old text := '   order by length(qvm_new_apps.normalize_part_number(r.code)) desc';
begin
  if position(v_old in v_def) = 0 then raise exception 'order by not found'; end if;
  -- The longest matching code still wins: it is the one that explains most of the number.
  -- Between two of the same length, the rule written for this tab beats the one written for
  -- every tab, so which one applied is never a matter of insertion order.
  execute replace(v_def, v_old,
    '   order by length(qvm_new_apps.normalize_part_number(r.code)) desc,' || E'\n' ||
    '            (r.record_kind is null)');
end
$mig$;
