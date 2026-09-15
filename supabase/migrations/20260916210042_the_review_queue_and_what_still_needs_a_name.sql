-- The two lists the review screen is made of.
--
-- part_enrichment_queue is what is waiting for a person, with everything needed to decide in the
-- row itself: what the part says now, what is proposed, what the gate made of it, and — where the
-- gate could not choose — the candidates it was choosing between. A reviewer who has to open
-- something else to decide stops reviewing by the twentieth row.
--
-- can_apply is computed here rather than in the browser on purpose. It is the same question the
-- apply function asks before writing, and answering it in two places is how a screen comes to
-- offer a tick that the server then refuses.
--
-- parts_missing_enrichment is the other half: what has no proposal yet and is worth asking about.
-- It is the button's input, and it is a query rather than a client-side filter so that «ask about
-- what is missing» cannot quietly become «ask about everything» — and so a part that already has
-- a proposal waiting is never paid for twice.
create or replace function qvm_new_apps.part_enrichment_queue(
  p_status  text default 'proposed',
  p_limit   integer default 100,
  p_offset  integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_rows jsonb; v_total bigint;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), coalesce(max(n), 0)
    into v_rows, v_total
    from (
      select count(*) over () as n, s.suggestion_id as ord, jsonb_build_object(
               'suggestion_id', s.suggestion_id,
               'part_number', s.clean_part_number,
               'field', s.field,
               'proposed_value', s.proposed_value,
               'confidence', s.confidence,
               'verdict', s.verdict,
               'status', s.status,
               'source', s.source, 'model', s.model,
               'created_at', s.created_at,
               -- what the part says today, so «is this an improvement» is answerable in place
               'current', jsonb_build_object(
                 'name_ar', c.clean_name_ar, 'name_en', c.clean_name_en,
                 'make', c.clean_make, 'part_class', c.clean_part_class,
                 'section_ar', sec.name_ar),
               -- where it would land
               'term', case when t.term_id is null then null else jsonb_build_object(
                 'term_id', t.term_id, 'code', t.code, 'name_ar', t.name_ar,
                 'name_en', t.name_en,
                 'section_ar', (select p.name_ar from qvm_new_apps.part_sections p
                                 where p.section_id = t.section_id)) end,
               -- and, when it would not land anywhere, what it was choosing between
               'candidates', coalesce(s.evidence->'gate'->'candidates', '[]'::jsonb),
               'evidence', s.evidence - 'gate',
               -- «yes» is only an answer once a term has been named
               'can_apply', (s.field <> 'name' or s.term_id is not null)
                            and c.clean_part_number is not null,
               'has_catalogue_row', c.clean_part_number is not null) as x
        from qvm_new_apps.part_enrichment_suggestions s
        left join qvm_new_apps.parts_catalog c on c.clean_part_number = s.clean_part_number
        left join qvm_new_apps.part_sections sec on sec.section_id = c.section_id
        left join qvm_new_apps.part_name_terms t on t.term_id = s.term_id
       where s.status = coalesce(nullif(p_status, ''), 'proposed')
       order by s.suggestion_id
       limit least(greatest(coalesce(p_limit, 100), 1), 500)
      offset greatest(coalesce(p_offset, 0), 0)) k;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total,
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                 from (select status, count(*) as n
                         from qvm_new_apps.part_enrichment_suggestions group by status) q)));
end
$$;

create or replace function qvm_new_apps.parts_missing_enrichment(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_rows jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'part_number', c.clean_part_number,
           'make', c.clean_make,
           -- whatever wording any file has ever used for it: free context for the model, and
           -- often the whole answer on its own
           'said_names', (select coalesce(jsonb_agg(distinct n.name), '[]'::jsonb)
                            from qvm_new_apps.parts_catalog_names n
                           where n.part_id = c.part_id and coalesce(n.name,'') <> ''),
           'missing', (case when c.clean_name_ar is null then jsonb_build_array('name')
                            else '[]'::jsonb end)
                   || (case when c.clean_make is null then jsonb_build_array('make')
                            else '[]'::jsonb end))
         order by c.clean_part_number), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.parts_catalog c
   where (c.clean_name_ar is null or c.clean_make is null)
     and qvm_new_apps.part_number_is_real(c.clean_part_number)
     and not exists (select 1 from qvm_new_apps.part_enrichment_suggestions s
                      where s.clean_part_number = c.clean_part_number and s.status = 'proposed')
   limit least(greatest(coalesce(p_limit, 50), 1), 200);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows,
    'total_missing', (select count(*) from qvm_new_apps.parts_catalog c
                       where (c.clean_name_ar is null or c.clean_make is null)
                         and qvm_new_apps.part_number_is_real(c.clean_part_number))));
end
$$;

revoke all on function qvm_new_apps.part_enrichment_queue(text, integer, integer) from public;
revoke all on function qvm_new_apps.parts_missing_enrichment(integer) from public;
grant execute on function qvm_new_apps.part_enrichment_queue(text, integer, integer),
                          qvm_new_apps.parts_missing_enrichment(integer)
  to authenticated, service_role;
