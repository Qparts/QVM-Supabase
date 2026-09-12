-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The upload screen offers the branches the header offers.
--
-- Same source as the header switcher — client_branches, narrowed by the caller's own
-- branch scope — so the branch someone picks while uploading is the branch they were
-- already looking at the system through, rather than a second, unrelated list of the
-- same word.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_page_get';
  if v_def is null then raise exception 'upload_page_get not found'; end if;
  if position('client_branches' in v_def) > 0 then return; end if;

  v_def := replace(v_def,
    E'      ''vendor_branches'', coalesce((select jsonb_agg(jsonb_build_object(',
    E'      ''client_branches'', coalesce((select jsonb_agg(jsonb_build_object(\n'
    || E'                             ''id'', cb.customer_id, ''name'', cb.branch_name,\n'
    || E'                             ''city'', cb.city, ''company'', ld.list_data)\n'
    || E'                           order by cb.branch_name)\n'
    || E'                             from qvm_new_apps.client_branches cb\n'
    || E'                             left join qvm_new_apps.list_data ld on ld.list_data_id = cb.list_data_id\n'
    || E'                            where coalesce(btrim(cb.branch_name), '''''''') <> ''''''''\n'
    || E'                              and (v_scope is null or cb.customer_id = any(v_scope))), ''[]''::jsonb),\n'
    || E'      ''vendor_branches'', coalesce((select jsonb_agg(jsonb_build_object(');

  v_def := replace(v_def,
    'v_vendor integer := qvm_new_apps.current_upload_vendor_id();',
    'v_vendor integer := qvm_new_apps.current_upload_vendor_id();' || E'\n'
    || '  v_scope integer[] := qvm_new_apps.get_internal_branch_scope(auth.uid());');

  if position('client_branches cb' in v_def) = 0 or position('v_scope' in v_def) = 0 then
    raise exception 'the client-branch list was not added';
  end if;
  execute v_def;
end $$;
