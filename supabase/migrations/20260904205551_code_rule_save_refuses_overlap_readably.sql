-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.upload_code_rule_save(bigint,jsonb,boolean,boolean)'::regprocedure);
  v_old text;
begin
  -- A source is what tells one supplier's «TH» from another's. Saving without one produced a
  -- rule that matches only files that have no source either — which is nothing anybody meant.
  v_old := '  if v_team then
    v_kind := coalesce(p_patch->>''source_kind'',''vendor'');';
  if position(v_old in v_def) = 0 then raise exception 'source block not found'; end if;
  v_def := replace(v_def, v_old, v_old);

  v_old := '  if p_rule_id is not null then
    select to_jsonb(r) into v_before from qvm_new_apps.upload_code_rules r';
  if position(v_old in v_def) = 0 then raise exception 'edit block not found'; end if;
  v_def := replace(v_def, v_old,
'  if v_sid is null then
    return jsonb_build_object(''status'', false,
      ''message'', ''اختر المصدر أولاً — نفس الكود يعني شيئاً مختلفاً عند كل مورد'', ''data'', null);
  end if;

  -- Already defined. Not left to the unique index: a rule with no tab applies to every tab, so
  -- it clashes with a scoped one without sharing its key, and the index would let that through.
  -- The message names the rule in the way, because «duplicate key» is not something anybody can
  -- act on.
  select r.rule_id into v_dup
    from qvm_new_apps.upload_code_rules r
   where r.rule_id is distinct from p_rule_id
     and r.source_kind = v_kind
     and coalesce(r.source_id, -1) = coalesce(v_sid, -1)
     and upper(r.code) = upper(btrim(p_patch->>''code''))
     and r.position = coalesce(p_patch->>''position'', ''prefix'')
     and (r.record_kind is null
          or nullif(btrim(coalesce(p_patch->>''record_kind'','''')), '''') is null
          or r.record_kind = p_patch->>''record_kind'')
   limit 1;

  if v_dup is not null then
    return jsonb_build_object(''status'', false,
      ''message'', ''هذا الكود معرَّف بالفعل لهذا المصدر بنفس الموضع — عدِّل القاعدة الموجودة بدل إضافة واحدة جديدة'',
      ''data'', jsonb_build_object(''existing_rule_id'', v_dup));
  end if;

' || v_old);

  v_old := '  v_kind text; v_sid bigint; v_label text; v_reprocessed integer := 0;';
  if position(v_old in v_def) = 0 then raise exception 'declare line not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n  v_dup bigint;');

  execute v_def;
end
$mig$;
