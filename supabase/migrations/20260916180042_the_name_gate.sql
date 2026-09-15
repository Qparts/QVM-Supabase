-- «Do we already say this?» — one call, answered against the curated dictionary.
--
-- This is the gate every name passes before it is allowed to become anything: a name a supplier
-- wrote, a name the cleanup produced, a name an AI proposed. It never writes. It reports what the
-- dictionary knows, and the caller decides what to do about it.
--
-- Five answers, and the useful thing is that they are five and not two:
--   exact             — the dictionary has this wording. Use its canonical spelling and move on.
--   near              — something close exists. A person confirms; nothing happens on its own.
--   position_mismatch — a term matched, but one side carries أمامي/يمين/خلفي and the other does
--                       not. NOT a match. See below.
--   ambiguous         — the source sheet files this wording under several terms and nobody has
--                       settled it. Held in part_name_conflicts.
--   new               — the dictionary has never seen it. A candidate for becoming a term.
--
-- position_mismatch exists because of a real case in the data. The dictionary has «قاعدة كرسي
-- مكينة» with no side; the catalogue has «كرسي مكينة يمين», «كرسي مكينة أيسر» and «كرسي مكينة
-- خلفي». Similarity alone happily collapses all three into the sideless term — and left and right
-- are the difference between the right part arriving and the wrong one. So a near match whose
-- position words do not agree is refused, loudly, and becomes a proposal to extend the dictionary
-- rather than a silent merge.

-- The position words — reported by MEANING, not by spelling.
--
-- The first draft returned the words themselves, and that was wrong in a way that would have
-- quietly discredited the whole guard: «فحمات فرامل أمامية» and «فحمات فرامل أمامي» read as two
-- different positions, feminine against masculine, and «Front Brake Pads» agreed with neither.
-- Honest matches would have been refused until someone learned to click past the warning. What
-- matters is front-ness, not which word carried it or in which language.
--
-- A named function rather than a literal buried in the gate: this list is the safety rule, and it
-- will be added to as the files teach us new wordings.
create or replace function qvm_new_apps.part_name_positions(p_norm text)
returns text[]
language sql
immutable
set search_path to 'qvm_new_apps', 'pg_catalog'
as $$
  select coalesce(array_agg(distinct p order by p), '{}'::text[])
    from unnest(string_to_array(coalesce(p_norm, ''), ' ')) as w
    cross join lateral (select case
      when w in ('امامي','اماميه','امامى','front','frt','fr')            then 'front'
      when w in ('خلفي','خلفيه','خلفى','rear','back','rr')               then 'rear'
      when w in ('يمين','ايمن','يمني','يمنى','right','rh')               then 'right'
      when w in ('يسار','ايسر','يسري','يسرى','شمال','left','lh')         then 'left'
      when w in ('علوي','علويه','علوى','اعلي','اعلى','فوقاني','upper','top')  then 'upper'
      when w in ('سفلي','سفليه','سفلى','اسفل','تحتاني','lower','bottom') then 'lower'
      when w in ('داخلي','داخليه','داخلى','inner','internal')            then 'inner'
      when w in ('خارجي','خارجيه','خارجى','outer','external')            then 'outer'
      when w in ('وسط','اوسط','اوسطي','mid','middle','center','centre')  then 'mid'
      end as p) x
   where p is not null;
$$;

create or replace function qvm_new_apps.part_name_resolve(
  p_name text,
  -- 0.62 sits above what an unrelated two-word Arabic name reaches and below the honest variants
  -- («غطاء الرادييتر» against «غطاء رديتر»). It only ever produces candidates for a person.
  p_threshold real default 0.62)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public', 'extensions'
as $$
declare
  v_norm  text := qvm_new_apps.normalize_part_name(p_name);
  v_pos   text[];
  v_hit   record;
  v_cands jsonb;
  v_agree jsonb;
  v_con   record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_norm is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data',
      jsonb_build_object('input', p_name, 'norm', null, 'verdict', 'empty',
                         'term', null, 'candidates', '[]'::jsonb));
  end if;
  v_pos := qvm_new_apps.part_name_positions(v_norm);

  -- 1 · the dictionary already has this wording. The load guarantees one term per wording, so
  --     there is nothing to choose between.
  select t.term_id, t.code, t.name_ar, t.name_en, t.section_id,
         s.name_ar as section_ar, s.name_en as section_en, y.text as matched_text
    into v_hit
    from qvm_new_apps.part_name_synonyms y
    join qvm_new_apps.part_name_terms t on t.term_id = y.term_id and t.is_active
    left join qvm_new_apps.part_sections s on s.section_id = t.section_id
   where y.norm = v_norm
   limit 1;
  if found then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'input', p_name, 'norm', v_norm, 'verdict', 'exact', 'positions', to_jsonb(v_pos),
      'matched_text', v_hit.matched_text,
      'term', jsonb_build_object('term_id', v_hit.term_id, 'code', v_hit.code,
              'name_ar', v_hit.name_ar, 'name_en', v_hit.name_en,
              'section_id', v_hit.section_id,
              'section_ar', v_hit.section_ar, 'section_en', v_hit.section_en),
      'candidates', '[]'::jsonb));
  end if;

  -- 2 · a wording the sheet could not decide. Say so rather than picking the first candidate —
  --     but rank the claimants by how close each one's own name is, so «رادييتر» opens on
  --     «رديتر» and not on the nine other radiator parts that also list it.
  select c.conflict_id, c.candidates into v_con
    from qvm_new_apps.part_name_conflicts c
   where c.norm = v_norm and c.status = 'open'
   limit 1;
  if found then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'input', p_name, 'norm', v_norm, 'verdict', 'ambiguous', 'positions', to_jsonb(v_pos),
      'conflict_id', v_con.conflict_id, 'term', null,
      'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
                       'term_id', t.term_id, 'code', t.code, 'name_ar', t.name_ar,
                       'name_en', t.name_en, 'section_ar', s.name_ar,
                       'similarity', round(extensions.similarity(
                         qvm_new_apps.normalize_part_name(t.name_ar), v_norm)::numeric, 3))
                       order by extensions.similarity(
                         qvm_new_apps.normalize_part_name(t.name_ar), v_norm) desc), '[]'::jsonb)
                       from qvm_new_apps.part_name_terms t
                       left join qvm_new_apps.part_sections s on s.section_id = t.section_id
                      where t.code in (select jsonb_array_elements_text(v_con.candidates)))));
  end if;

  -- 3 · the near neighbours, and separately the ones whose position words agree with the input.
  --     Splitting them is what turns «FRT BRAKE PADS» into a match on «فحمات فرامل أمامي» rather
  --     than a refusal against «فحمات», which merely scored higher on letters.
  select coalesce(jsonb_agg(x order by x->>'similarity' desc), '[]'::jsonb),
         coalesce(jsonb_agg(x order by x->>'similarity' desc)
                    filter (where (x->'positions')::jsonb = to_jsonb(v_pos)), '[]'::jsonb)
    into v_cands, v_agree
    from (
      select jsonb_build_object(
               'term_id', t.term_id, 'code', t.code, 'name_ar', t.name_ar, 'name_en', t.name_en,
               'section_id', t.section_id, 'section_ar', s.name_ar, 'section_en', s.name_en,
               'matched_text', y.text,
               'similarity', round(extensions.similarity(y.norm, v_norm)::numeric, 3),
               'positions', to_jsonb(qvm_new_apps.part_name_positions(y.norm))) as x
        from qvm_new_apps.part_name_synonyms y
        join qvm_new_apps.part_name_terms t on t.term_id = y.term_id and t.is_active
        left join qvm_new_apps.part_sections s on s.section_id = t.section_id
       where y.norm % v_norm
         and extensions.similarity(y.norm, v_norm) >= p_threshold
       order by extensions.similarity(y.norm, v_norm) desc
       limit 8) k;

  if jsonb_array_length(v_cands) = 0 then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'input', p_name, 'norm', v_norm, 'verdict', 'new', 'positions', to_jsonb(v_pos),
      'term', null, 'candidates', '[]'::jsonb));
  end if;

  -- 4 · not one neighbour carries the same position. The dictionary has no term for this part
  --     yet, and saying «near» here is how «كرسي مكينة أيسر» quietly becomes the right-hand one.
  if jsonb_array_length(v_agree) = 0 then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'input', p_name, 'norm', v_norm, 'verdict', 'position_mismatch',
      'positions', to_jsonb(v_pos), 'term', null, 'candidates', v_cands));
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'input', p_name, 'norm', v_norm, 'verdict', 'near', 'positions', to_jsonb(v_pos),
    'term', null, 'candidates', v_agree, 'also_near', v_cands));
end
$$;

revoke all on function qvm_new_apps.part_name_resolve(text, real) from public;
grant execute on function qvm_new_apps.part_name_resolve(text, real) to authenticated, service_role;
grant execute on function qvm_new_apps.part_name_positions(text) to authenticated, service_role;
