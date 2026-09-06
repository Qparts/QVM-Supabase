-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_clean_row(jsonb,text,text,bigint)'::regprocedure);
  v_old text;
begin
  v_old := '  select r.*, qvm_new_apps.normalize_part_number(r.code) as norm_code into v_rule
    from qvm_new_apps.upload_code_rules r
   where r.source_kind = p_source_kind
     and coalesce(r.source_id, -1) = coalesce(p_source_id, -1)
     -- A rule belongs to one records tab. An older rule has no tab and still applies to
     -- every file, which is what it meant when it was written.
     and (r.record_kind is null
          or r.record_kind = qvm_new_apps.upload_template_record_kind(p_template_key))
     and qvm_new_apps.normalize_part_number(r.code) is not null
     and ( (r.position = ''prefix''
            and v_pn_norm like qvm_new_apps.normalize_part_number(r.code) || ''%'')
        or (r.position = ''suffix''
            and v_pn_norm like ''%'' || qvm_new_apps.normalize_part_number(r.code)) )
   order by length(qvm_new_apps.normalize_part_number(r.code)) desc,
            (r.record_kind is null)
   limit 1;';

  if position(v_old in v_def) = 0 then raise exception 'rule select block not found'; end if;

  -- Everything from the rule match down to what is stored now comes from the shared policy,
  -- so a typed number and an imported one cannot be cleaned differently.
  v_def := replace(v_def, v_old,
'  v_clean := qvm_new_apps.upload_clean_part_number(
                v_pn_raw,
                qvm_new_apps.upload_template_record_kind(p_template_key),
                p_source_kind, p_source_id);

  select * into v_rule from qvm_new_apps.upload_code_rules r
   where r.rule_id = nullif(v_clean->>''matched_rule_id'','''')::bigint;');

  -- The stripping and treatment lines the shared function now owns.
  v_old := '  -- The part number with the matched code taken off, whatever the treatment.
  -- Used only to decide whether anything *else* is still unexplained.
  v_stripped := v_pn_raw;
  if v_rule.rule_id is not null then
    v_code := v_rule.norm_code;
    if v_rule.position = ''prefix'' then
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(left(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(substr(v_pn_raw, v_cut + 2), ''-_. '');
    else
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(right(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(left(v_pn_raw, length(v_pn_raw) - v_cut - 1), ''-_. '');
    end if;
    if coalesce(v_stripped, '''') = '''' then v_stripped := v_pn_raw; end if;
  end if;

  -- What is actually stored: stripped only when the rule says to strip.
  v_work  := case when v_rule.rule_id is not null and v_rule.treatment = ''strip''
                  then v_stripped else v_pn_raw end;
  v_probe := case when v_rule.rule_id is not null then v_stripped else v_pn_raw end;';

  if position(v_old in v_def) = 0 then raise exception 'strip block not found'; end if;
  v_def := replace(v_def, v_old,
'  v_work  := v_clean->>''display_part_number'';
  v_probe := v_clean->>''probe'';');

  v_old := '  v_unknown boolean; v_cut integer; v_key text;';
  if position(v_old in v_def) = 0 then raise exception 'declare line not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n  v_clean jsonb;');

  execute v_def;
end
$mig$;
