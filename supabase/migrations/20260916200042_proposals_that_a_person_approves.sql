-- Proposals, and the one act that turns a proposal into a fact.
--
-- Everything upstream — the cleanup, the family, the AI — produces a suggestion. Nothing upstream
-- writes. This is where a person says yes, and it is deliberately the only place, because the
-- difference between a system you can trust and one you cannot is whether a machine's guess can
-- reach the catalogue without someone having read it.
--
-- Approving a name does three things at once, and the third is the one that compounds:
--   · the part gets the dictionary's canonical spelling and its section
--   · the part is linked to the term, so the two can never drift
--   · the wording that was proposed is registered as a synonym of that term
-- After which the same wording, from any supplier, in any file, resolves for free and is never
-- asked about again. The cost of the system falls as it is used.
--
-- Three verdicts cannot be approved at all — ambiguous, position_mismatch, new. Not because the
-- reviewer is not trusted, but because «yes» is not an answer to any of them: they ask WHICH term,
-- and the answer has to name one. Each has its own action below.

-- A part points at its vocabulary term. Additive: every existing reader of clean_name_ar keeps
-- working, and the link is what lets a later correction to the term reach every part that uses it.
alter table qvm_new_apps.parts_catalog
  add column if not exists term_id bigint references qvm_new_apps.part_name_terms(term_id);

create table if not exists qvm_new_apps.part_enrichment_suggestions (
  suggestion_id     bigint generated always as identity primary key,
  clean_part_number text   not null,
  -- name | make | part_class. The section is not a field here: it arrives with the term, because
  -- a section chosen independently of the name is how a brake pad ends up filed under filters.
  field             text   not null,
  proposed_value    text,
  -- Set when the gate resolved the wording to a term. Null for make and part_class.
  term_id           bigint references qvm_new_apps.part_name_terms(term_id),
  -- The gate's reading at the time of proposing, kept as evidence rather than recomputed: the
  -- dictionary changes, and «why was this suggested» must still be answerable next month.
  verdict           text,
  confidence        numeric(4,3),
  -- Whatever the proposer relied on: the model, the sources, the sibling parts, the raw names,
  -- the candidates the gate offered. Never summarised away.
  evidence          jsonb  not null default '{}'::jsonb,
  source            text   not null default 'ai',       -- ai | family | cleanup | human
  model             text,
  tokens_in         integer,
  tokens_out        integer,
  status            text   not null default 'proposed', -- proposed | applied | rejected | superseded
  -- Everything the apply overwrote, so undo is a restore and not a second guess.
  previous          jsonb,
  note              text,
  created_at        timestamptz not null default now(),
  decided_at        timestamptz,
  decided_by        uuid
);

-- One open proposal per part per field: a second run of the same enrichment supersedes the first
-- rather than stacking two answers in front of the reviewer.
create unique index if not exists part_enrichment_open_one
  on qvm_new_apps.part_enrichment_suggestions (clean_part_number, field)
  where status = 'proposed';
create index if not exists part_enrichment_status
  on qvm_new_apps.part_enrichment_suggestions (status, verdict);

alter table qvm_new_apps.part_enrichment_suggestions enable row level security;
grant select on qvm_new_apps.part_enrichment_suggestions to authenticated;

-- ── A number worth spending anything on ────────────────────────────────────────────────────────
-- The catalogue contains «1», «123», «1234» and names like «تيست» and «ar». Sending those to a
-- model costs tokens and sending their answers to a reviewer costs something scarcer. This is the
-- filter every proposer runs first.
create or replace function qvm_new_apps.part_number_is_real(p_number text)
returns boolean
language sql
immutable
set search_path to 'qvm_new_apps', 'pg_catalog'
as $$
  select p_number is not null
     and length(p_number) >= 5
     -- a real part number is not a single repeated digit, and not 12345
     and p_number !~ '^(.)\1*$'
     and p_number !~ '^0*123456?7?8?9?$';
$$;

-- ── Proposing ──────────────────────────────────────────────────────────────────────────────────
-- Takes whatever the AI (or the family rung, or a person) came up with, runs each name through
-- the gate, and files the result. It decides nothing.
create or replace function qvm_new_apps.part_enrichment_propose(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  r        record;
  v_gate   jsonb;
  v_term   bigint;
  v_kept   integer := 0;
  v_skipped integer := 0;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  for r in
    select * from jsonb_to_recordset(p_items) as x(
      part_number text, field text, value text, confidence numeric,
      evidence jsonb, source text, model text, tokens_in integer, tokens_out integer)
  loop
    if not qvm_new_apps.part_number_is_real(r.part_number)
       or coalesce(btrim(r.value), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_gate := null; v_term := null;
    if r.field = 'name' then
      v_gate := qvm_new_apps.part_name_resolve(r.value) -> 'data';
      -- Only an exact reading carries a term. «near» names its candidates and lets the reviewer
      -- pick; writing the top candidate in here would make the pick look already made.
      if v_gate->>'verdict' = 'exact' then
        v_term := (v_gate->'term'->>'term_id')::bigint;
      end if;
    end if;

    insert into qvm_new_apps.part_enrichment_suggestions
      (clean_part_number, field, proposed_value, term_id, verdict, confidence,
       evidence, source, model, tokens_in, tokens_out)
    values (r.part_number, r.field, btrim(r.value), v_term,
            coalesce(v_gate->>'verdict', 'n/a'), r.confidence,
            coalesce(r.evidence, '{}'::jsonb) ||
              case when v_gate is null then '{}'::jsonb else jsonb_build_object('gate', v_gate) end,
            coalesce(nullif(r.source, ''), 'ai'), r.model, r.tokens_in, r.tokens_out)
    on conflict (clean_part_number, field) where status = 'proposed'
    do update set proposed_value = excluded.proposed_value, term_id = excluded.term_id,
                  verdict = excluded.verdict, confidence = excluded.confidence,
                  evidence = excluded.evidence, model = excluded.model,
                  tokens_in = excluded.tokens_in, tokens_out = excluded.tokens_out,
                  created_at = now();
    v_kept := v_kept + 1;
  end loop;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'proposed', v_kept, 'skipped', v_skipped,
    'open', (select count(*) from qvm_new_apps.part_enrichment_suggestions where status = 'proposed')));
end
$$;

-- ── Approving ──────────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.part_enrichment_apply(p_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  s        record;
  t        record;
  v_prev   jsonb;
  v_done   integer := 0;
  v_refused jsonb := '[]'::jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  for s in
    select * from qvm_new_apps.part_enrichment_suggestions
     where suggestion_id = any(p_ids) and status = 'proposed'
     order by suggestion_id
  loop
    -- «Yes» is not an answer to «which one». These have their own actions.
    if s.field = 'name' and s.term_id is null then
      v_refused := v_refused || jsonb_build_object(
        'suggestion_id', s.suggestion_id, 'verdict', s.verdict,
        'why', 'a name proposal must name a term — resolve the conflict or add the term first');
      continue;
    end if;
    if not exists (select 1 from qvm_new_apps.parts_catalog c
                    where c.clean_part_number = s.clean_part_number) then
      v_refused := v_refused || jsonb_build_object(
        'suggestion_id', s.suggestion_id, 'why', 'no catalogue row for this part number');
      continue;
    end if;

    if s.field = 'name' then
      select * into t from qvm_new_apps.part_name_terms where term_id = s.term_id;

      select jsonb_build_object('clean_name_ar', c.clean_name_ar, 'clean_name_en', c.clean_name_en,
                                'section_id', c.section_id, 'term_id', c.term_id)
        into v_prev
        from qvm_new_apps.parts_catalog c where c.clean_part_number = s.clean_part_number limit 1;

      update qvm_new_apps.parts_catalog
         set clean_name_ar = t.name_ar, clean_name_en = coalesce(t.name_en, clean_name_en),
             section_id = coalesce(t.section_id, section_id), term_id = t.term_id,
             updated_at = now()
       where clean_part_number = s.clean_part_number;

      -- The wording that was proposed joins the dictionary, so the next file carrying it lands
      -- for free. This is the line that makes the system cheaper the more it is used.
      insert into qvm_new_apps.part_name_synonyms (term_id, text, lang, is_canonical, origin)
      select t.term_id, s.proposed_value,
             case when s.proposed_value ~ '[؀-ۿ]' then 'ar' else 'en' end, false, s.source
       where qvm_new_apps.normalize_part_name(s.proposed_value) is not null
         -- never steal a wording another term already owns
         and not exists (select 1 from qvm_new_apps.part_name_synonyms y
                          where y.norm = qvm_new_apps.normalize_part_name(s.proposed_value))
      on conflict (term_id, norm) do nothing;

    elsif s.field = 'make' then
      select jsonb_build_object('clean_make', c.clean_make) into v_prev
        from qvm_new_apps.parts_catalog c where c.clean_part_number = s.clean_part_number limit 1;
      update qvm_new_apps.parts_catalog set clean_make = s.proposed_value, updated_at = now()
       where clean_part_number = s.clean_part_number;

    elsif s.field = 'part_class' then
      select jsonb_build_object('clean_part_class', c.clean_part_class) into v_prev
        from qvm_new_apps.parts_catalog c where c.clean_part_number = s.clean_part_number limit 1;
      update qvm_new_apps.parts_catalog set clean_part_class = s.proposed_value, updated_at = now()
       where clean_part_number = s.clean_part_number;

    else
      v_refused := v_refused || jsonb_build_object('suggestion_id', s.suggestion_id,
        'why', 'unknown field ' || s.field);
      continue;
    end if;

    update qvm_new_apps.part_enrichment_suggestions
       set status = 'applied', previous = v_prev, decided_at = now(), decided_by = auth.uid()
     where suggestion_id = s.suggestion_id;
    v_done := v_done + 1;
  end loop;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'applied', v_done, 'refused', v_refused));
end
$$;

-- ── Undoing ────────────────────────────────────────────────────────────────────────────────────
-- A restore from what was recorded, not a second opinion about what the value should be.
create or replace function qvm_new_apps.part_enrichment_undo(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare s record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into s from qvm_new_apps.part_enrichment_suggestions
   where suggestion_id = p_id and status = 'applied';
  if not found then
    return jsonb_build_object('status', false, 'message', 'not an applied suggestion', 'data', null);
  end if;

  if s.field = 'name' then
    update qvm_new_apps.parts_catalog
       set clean_name_ar = s.previous->>'clean_name_ar',
           clean_name_en = s.previous->>'clean_name_en',
           section_id    = nullif(s.previous->>'section_id','')::bigint,
           term_id       = nullif(s.previous->>'term_id','')::bigint,
           updated_at    = now()
     where clean_part_number = s.clean_part_number;
  elsif s.field = 'make' then
    update qvm_new_apps.parts_catalog set clean_make = s.previous->>'clean_make', updated_at = now()
     where clean_part_number = s.clean_part_number;
  elsif s.field = 'part_class' then
    update qvm_new_apps.parts_catalog set clean_part_class = s.previous->>'clean_part_class',
           updated_at = now()
     where clean_part_number = s.clean_part_number;
  end if;

  -- The synonym it taught the dictionary stays. It was a true statement about wording — this part
  -- being wrong does not make «FRT BRAKE PADS» stop meaning front brake pads — and removing it
  -- would silently undo learning that other parts are already relying on.
  update qvm_new_apps.part_enrichment_suggestions
     set status = 'rejected', note = coalesce(note || ' · ', '') || 'undone after applying',
         decided_at = now(), decided_by = auth.uid()
   where suggestion_id = p_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data',
    jsonb_build_object('restored', s.previous));
end
$$;

create or replace function qvm_new_apps.part_enrichment_reject(p_ids bigint[], p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_n integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  update qvm_new_apps.part_enrichment_suggestions
     set status = 'rejected', note = p_note, decided_at = now(), decided_by = auth.uid()
   where suggestion_id = any(p_ids) and status = 'proposed';
  get diagnostics v_n = row_count;
  return jsonb_build_object('status', true, 'message', 'ok',
                            'data', jsonb_build_object('rejected', v_n));
end
$$;

revoke all on function qvm_new_apps.part_enrichment_propose(jsonb) from public;
revoke all on function qvm_new_apps.part_enrichment_apply(bigint[]) from public;
revoke all on function qvm_new_apps.part_enrichment_undo(bigint) from public;
revoke all on function qvm_new_apps.part_enrichment_reject(bigint[], text) from public;
grant execute on function qvm_new_apps.part_enrichment_propose(jsonb),
                          qvm_new_apps.part_enrichment_apply(bigint[]),
                          qvm_new_apps.part_enrichment_undo(bigint),
                          qvm_new_apps.part_enrichment_reject(bigint[], text),
                          qvm_new_apps.part_number_is_real(text)
  to authenticated, service_role;
