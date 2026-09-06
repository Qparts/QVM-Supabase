-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Completing a part is the whole point of the catalog tab: a row lands incomplete from an upload
-- that could not know the country, and a person fills it in. Without this the tab could show what
-- is missing but never let anyone fix it.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='qvm_new_apps' and p.proname='uploaded_record_update';
  if strpos(v_def, 'parts_catalog') > 0 then raise notice 'already handled'; return; end if;

  v_def := replace(v_def,
'  if p_kind = ''agency'' then',
'  if p_kind = ''catalog'' then
    if not v_team then
      return jsonb_build_object(''status'', false, ''message'', ''forbidden'', ''data'', null);
    end if;
    update qvm_new_apps.parts_catalog set
      clean_name_ar = case when p_patch ? ''name'' then nullif(btrim(p_patch->>''name''),'''') else clean_name_ar end,
      clean_name_en = case when p_patch ? ''name_en'' then nullif(btrim(p_patch->>''name_en''),'''') else clean_name_en end,
      clean_make    = case when p_patch ? ''make'' then coalesce(nullif(btrim(p_patch->>''make''),''''), clean_make) else clean_make end,
      clean_part_class = case when p_patch ? ''part_class'' then nullif(btrim(p_patch->>''part_class''),'''') else clean_part_class end,
      clean_country_manufacture = case when p_patch ? ''country'' then nullif(btrim(p_patch->>''country''),'''') else clean_country_manufacture end,
      updated_at = now()
     where part_id = p_id;
    get diagnostics v_n = row_count;

    -- A canonical name a person typed joins the recorded wordings, so searching by it finds the part.
    if v_n > 0 and p_patch ? ''name'' and nullif(btrim(p_patch->>''name''), '''') is not null then
      insert into qvm_new_apps.parts_catalog_names (part_id, name, used_by, lang)
      values (p_id, btrim(p_patch->>''name''), ''canonical'', ''ar'') on conflict do nothing;
    end if;

  elsif p_kind = ''agency'' then');

  if strpos(v_def, 'parts_catalog') = 0 then
    raise exception 'the anchor in uploaded_record_update was not found';
  end if;
  execute v_def;
end $$;
