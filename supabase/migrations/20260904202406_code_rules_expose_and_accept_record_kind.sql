-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text;
  v_old text;
begin
  -- The rules list carries its scope, so the screen can show one tab's rules.
  v_def := pg_get_functiondef('qvm_new_apps.upload_page_get()'::regprocedure);
  v_old := '               ''brand'', r.brand, ''part_class'', r.part_class,';
  if position(v_old in v_def) = 0 then raise exception 'page_get rules line not found'; end if;
  execute replace(v_def, v_old,
    '               ''brand'', r.brand, ''part_class'', r.part_class,' || E'\n' ||
    '               ''record_kind'', r.record_kind,');

  -- Saving one keeps the scope it was created under.
  v_def := pg_get_functiondef('qvm_new_apps.upload_code_rule_save(bigint,jsonb,boolean,boolean)'::regprocedure);

  v_old := '      part_class = coalesce(nullif(btrim(coalesce(p_patch->>''part_class'','''')), ''''), r.part_class),';
  if position(v_old in v_def) = 0 then raise exception 'save update line not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n' ||
    '      record_kind = nullif(btrim(coalesce(p_patch->>''record_kind'','''')), ''''),');

  v_old := '      (source_kind, source_id, source_label, code, position, treatment,
       brand, part_class, country_of_origin, created_by)';
  if position(v_old in v_def) = 0 then raise exception 'save insert column list not found'; end if;
  v_def := replace(v_def, v_old,
    '      (source_kind, source_id, source_label, code, position, treatment,
       brand, part_class, country_of_origin, record_kind, created_by)');

  v_old := '            nullif(btrim(coalesce(p_patch->>''country_of_origin'','''')), ''''),
            auth.uid())';
  if position(v_old in v_def) = 0 then raise exception 'save insert values not found'; end if;
  v_def := replace(v_def, v_old,
    '            nullif(btrim(coalesce(p_patch->>''country_of_origin'','''')), ''''),
            nullif(btrim(coalesce(p_patch->>''record_kind'','''')), ''''),
            auth.uid())');

  execute v_def;
end
$mig$;
