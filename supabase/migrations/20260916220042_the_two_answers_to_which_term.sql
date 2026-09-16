-- The two actions that were missing, and without which the queue is a wall.
--
-- 20260916200042 correctly refuses to apply a proposal the dictionary could not place, because
-- «yes» is not an answer to «which term». It said each of those verdicts would have its own
-- action. It did not build them — so every near and every new suggestion arrived with no tick
-- and nothing else either, and a reviewer looking at sixteen rows could do nothing at all. The
-- guard was right and the screen was useless, which is the worst of the two combinations.
--
-- There are exactly two answers to «which term», and these are they:
--   · name one that exists      → part_enrichment_choose_term
--   · there is none; make it    → part_name_term_add
--
-- Neither invents anything. Choosing names a term the reviewer can see; adding takes the Arabic
-- name and the section FROM the reviewer, because that is precisely what cannot be derived: the
-- whole value of this dictionary is that «Wheel Bearing» is «رمان كفر», which no translation of
-- those two words produces.

-- ── Naming an existing term ────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.part_enrichment_choose_term(
  p_id bigint, p_term_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare s record; t record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into s from qvm_new_apps.part_enrichment_suggestions
   where suggestion_id = p_id and status = 'proposed';
  if not found then
    return jsonb_build_object('status', false, 'message', 'no open suggestion', 'data', null);
  end if;
  select * into t from qvm_new_apps.part_name_terms where term_id = p_term_id and is_active;
  if not found then
    return jsonb_build_object('status', false, 'message', 'unknown term', 'data', null);
  end if;

  -- The choice is recorded on the suggestion and the verdict is rewritten to say a person made
  -- it. Keeping «near» here would lose the one fact that matters later: this was not the gate's
  -- reading, it was somebody's decision, and an accuracy review has to tell them apart.
  update qvm_new_apps.part_enrichment_suggestions
     set term_id = t.term_id,
         verdict = 'chosen',
         evidence = evidence || jsonb_build_object('chosen_by_person', jsonb_build_object(
                      'at', now(), 'by', auth.uid(), 'was', s.verdict))
   where suggestion_id = p_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'suggestion_id', p_id, 'term_id', t.term_id, 'name_ar', t.name_ar));
end
$$;

-- ── Making the term that does not exist ────────────────────────────────────────────────────────
create or replace function qvm_new_apps.part_name_term_add(
  p_name_ar    text,
  p_section_id bigint,
  p_name_en    text default null,
  -- The wording that prompted this, registered as a synonym so the same file never asks again.
  p_synonym    text default null,
  -- When given, the suggestion that asked for it is pointed at the new term in the same breath.
  p_suggestion bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_term bigint; v_clash record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if qvm_new_apps.normalize_part_name(p_name_ar) is null then
    return jsonb_build_object('status', false, 'message', 'الاسم العربي مطلوب', 'data', null);
  end if;
  if not exists (select 1 from qvm_new_apps.part_sections
                  where section_id = p_section_id and is_active) then
    return jsonb_build_object('status', false, 'message', 'القسم مطلوب', 'data', null);
  end if;

  -- A new term whose name is already a wording of another term would break the one invariant the
  -- gate depends on: one wording, one term. Refuse, and say which term already has it.
  select t.term_id, t.name_ar into v_clash
    from qvm_new_apps.part_name_synonyms y
    join qvm_new_apps.part_name_terms t on t.term_id = y.term_id
   where y.norm = qvm_new_apps.normalize_part_name(p_name_ar)
   limit 1;
  if found then
    return jsonb_build_object('status', false, 'data', jsonb_build_object('term_id', v_clash.term_id),
      'message', 'هذه الصياغة موجودة بالفعل تحت «' || v_clash.name_ar || '»');
  end if;

  insert into qvm_new_apps.part_name_terms (code, name_ar, name_en, section_id, origin)
  values (null, btrim(p_name_ar), nullif(btrim(coalesce(p_name_en, '')), ''), p_section_id, 'human')
  returning term_id into v_term;

  -- Its own two names, indexed like every other term's, so it is findable the moment it exists.
  insert into qvm_new_apps.part_name_synonyms (term_id, text, lang, is_canonical, origin)
  select v_term, x.txt, x.lang, true, 'human'
    from (values (btrim(p_name_ar), 'ar'), (nullif(btrim(coalesce(p_name_en,'')), ''), 'en')) as x(txt, lang)
   where x.txt is not null
     and qvm_new_apps.normalize_part_name(x.txt) is not null
     and not exists (select 1 from qvm_new_apps.part_name_synonyms y
                      where y.norm = qvm_new_apps.normalize_part_name(x.txt))
  on conflict (term_id, norm) do nothing;

  if p_synonym is not null and qvm_new_apps.normalize_part_name(p_synonym) is not null then
    insert into qvm_new_apps.part_name_synonyms (term_id, text, lang, is_canonical, origin)
    select v_term, btrim(p_synonym),
           case when p_synonym ~ '[؀-ۿ]' then 'ar' else 'en' end, false, 'human'
     where not exists (select 1 from qvm_new_apps.part_name_synonyms y
                        where y.norm = qvm_new_apps.normalize_part_name(p_synonym))
    on conflict (term_id, norm) do nothing;
  end if;

  if p_suggestion is not null then
    update qvm_new_apps.part_enrichment_suggestions
       set term_id = v_term, verdict = 'chosen',
           evidence = evidence || jsonb_build_object('term_created', jsonb_build_object(
                        'at', now(), 'by', auth.uid(), 'was', verdict))
     where suggestion_id = p_suggestion and status = 'proposed';
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'term_id', v_term, 'name_ar', btrim(p_name_ar)));
end
$$;

-- ── Finding a term to name ─────────────────────────────────────────────────────────────────────
-- The candidates the gate offered are usually enough, but not always: a reviewer who knows the
-- right term is not served by a list that does not contain it.
create or replace function qvm_new_apps.part_name_terms_search(
  p_q text default null, p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public', 'extensions'
as $$
declare v_norm text := qvm_new_apps.normalize_part_name(p_q);
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data',
    (select coalesce(jsonb_agg(jsonb_build_object(
       'term_id', t.term_id, 'name_ar', t.name_ar, 'name_en', t.name_en,
       'section_id', t.section_id, 'section_ar', s.name_ar) order by rank, t.name_ar), '[]'::jsonb)
       from (
         select t.*, min(case when y.norm = v_norm then 0
                              else 1 - coalesce(extensions.similarity(y.norm, v_norm), 0) end) as rank
           from qvm_new_apps.part_name_terms t
           join qvm_new_apps.part_name_synonyms y on y.term_id = t.term_id
          where t.is_active
            and (v_norm is null or y.norm like '%'||v_norm||'%' or y.norm % v_norm)
          group by t.term_id, t.code, t.name_ar, t.name_en, t.section_id, t.is_active,
                   t.origin, t.created_at, t.updated_at
          order by rank
          limit least(greatest(coalesce(p_limit, 20), 1), 100)) t
       left join qvm_new_apps.part_sections s on s.section_id = t.section_id));
end
$$;

revoke all on function qvm_new_apps.part_enrichment_choose_term(bigint, bigint) from public;
revoke all on function qvm_new_apps.part_name_term_add(text, bigint, text, text, bigint) from public;
revoke all on function qvm_new_apps.part_name_terms_search(text, integer) from public;
grant execute on function qvm_new_apps.part_enrichment_choose_term(bigint, bigint),
                          qvm_new_apps.part_name_term_add(text, bigint, text, text, bigint),
                          qvm_new_apps.part_name_terms_search(text, integer)
  to authenticated, service_role;
