-- The loader for the curated dictionary, and the one call that runs it.
--
-- 615 terms and their 2,070 wordings are data, not schema, and shipping 150 KB of Arabic text as
-- literals in a migration makes the migration unreadable and unreviewable. It arrives as three
-- JSON arrays instead, and this decides what to do with each row.
--
-- Idempotent on purpose: a term is matched by its sheet code and a wording by (term, normalised
-- form), so running it twice changes nothing and a corrected sheet can be re-sent without first
-- undoing anything.
--
-- What it will not do is resolve an ambiguity. A wording that the sheet files under more than one
-- term is not decided here by popularity or by order — it lands in part_name_conflicts with every
-- candidate attached, and stays out of the dictionary until a person says which one it is. That
-- is the whole reason the dictionary can be trusted by everything downstream.
create or replace function qvm_new_apps.part_name_dictionary_load(
  p_terms     jsonb,
  p_synonyms  jsonb,
  p_conflicts jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_terms integer; v_syn integer; v_con integer;
  v_missing_section jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- A term whose section is not in part_sections would land with a null section and look filed
  -- when it is not. Say so and change nothing rather than load a quiet hole.
  select coalesce(jsonb_agg(distinct x.sec), '[]'::jsonb) into v_missing_section
    from jsonb_to_recordset(p_terms) as x(code text, ar text, en text, sec text)
   where not exists (select 1 from qvm_new_apps.part_sections s
                      where s.name_ar = x.sec and s.is_active);
  if jsonb_array_length(v_missing_section) > 0 then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'unknown sections: ' || v_missing_section::text);
  end if;

  insert into qvm_new_apps.part_name_terms (code, name_ar, name_en, section_id, origin)
  select x.code, x.ar, nullif(x.en, ''), s.section_id, 'dictionary'
    from jsonb_to_recordset(p_terms) as x(code text, ar text, en text, sec text)
    join qvm_new_apps.part_sections s on s.name_ar = x.sec and s.is_active
  on conflict (code) do update
     set name_ar = excluded.name_ar, name_en = excluded.name_en,
         section_id = excluded.section_id, updated_at = now()
   where qvm_new_apps.part_name_terms.name_ar    is distinct from excluded.name_ar
      or qvm_new_apps.part_name_terms.name_en    is distinct from excluded.name_en
      or qvm_new_apps.part_name_terms.section_id is distinct from excluded.section_id;
  get diagnostics v_terms = row_count;

  insert into qvm_new_apps.part_name_synonyms (term_id, text, lang, is_canonical, origin)
  select t.term_id, x.txt, nullif(x.lang, ''), coalesce(x.canon, false), 'dictionary'
    from jsonb_to_recordset(p_synonyms) as x(code text, txt text, lang text, canon boolean)
    join qvm_new_apps.part_name_terms t on t.code = x.code
   where qvm_new_apps.normalize_part_name(x.txt) is not null
  on conflict (term_id, norm) do nothing;
  get diagnostics v_syn = row_count;

  insert into qvm_new_apps.part_name_conflicts (text, candidates, note)
  select x.txt, x.cand, coalesce(nullif(x.note, ''), 'listed under more than one term in the source sheet')
    from jsonb_to_recordset(p_conflicts) as x(txt text, cand jsonb, note text)
   where qvm_new_apps.normalize_part_name(x.txt) is not null
  on conflict (norm) do nothing;
  get diagnostics v_con = row_count;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'terms_written', v_terms, 'synonyms_written', v_syn, 'conflicts_written', v_con,
    'terms_total',     (select count(*) from qvm_new_apps.part_name_terms),
    'synonyms_total',  (select count(*) from qvm_new_apps.part_name_synonyms),
    'conflicts_open',  (select count(*) from qvm_new_apps.part_name_conflicts where status = 'open')));
end
$$;

revoke all on function qvm_new_apps.part_name_dictionary_load(jsonb, jsonb, jsonb) from public;
grant execute on function qvm_new_apps.part_name_dictionary_load(jsonb, jsonb, jsonb)
  to authenticated, service_role;
