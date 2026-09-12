-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- «Re:» is an answer. On a conversation we opened, the first mail carrying it makes the
-- vendor look for a message they never received. It is added only once they have written.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'wa_send_message';

  if v_def is null then raise exception 'wa_send_message not found'; end if;
  if position('v_has_inbound' in v_def) > 0 then return; end if;

  -- Declare the flag alongside the other locals.
  v_def := replace(v_def,
    '  v_channel text; v_to_email text; v_email_account bigint; v_subject text;',
    '  v_channel text; v_to_email text; v_email_account bigint; v_subject text;'
    || E'\n  v_has_inbound boolean := false;');
  if position('v_has_inbound boolean' in v_def) = 0 then
    raise exception 'could not add the declaration';
  end if;

  -- Set it just before the outbox insert, where the channel is already known.
  v_def := replace(v_def,
    '  if not v_note then' || E'\n' || '    if v_channel = ''email'' then',
    '  if not v_note then' || E'\n'
    || '    if v_channel = ''email'' then' || E'\n'
    || '      select exists (select 1 from qvm_new_apps.wa_messages m' || E'\n'
    || '                      where m.thread_id = p_thread_id and m.direction = ''in'')' || E'\n'
    || '        into v_has_inbound;');
  if position('into v_has_inbound' in v_def) = 0 then
    raise exception 'could not add the lookup';
  end if;

  v_def := replace(v_def,
    'case when coalesce(v_subject,'''') = '''' then ''Re:''',
    'case when not v_has_inbound then coalesce(nullif(v_subject, ''''), ''(no subject)'')' || E'\n'
    || '                   when coalesce(v_subject,'''') = '''' then ''Re:''');
  if position('when not v_has_inbound then' in v_def) = 0 then
    raise exception 'could not rewrite the subject';
  end if;

  execute v_def;
end $$;
