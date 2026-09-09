-- Two faults on the same screen, both of them about what «here» means.
--
-- ① The four cards at the top of a tab were counting every batch in the system. Standing on Past
-- Purchases, whose own list held one file, they read «3 files, 60 accepted, 20 rejected» — the
-- totals for Agency and Stock folded in. A summary that answers a question nobody asked is worse
-- than no summary, because it is read as the answer to the one they did ask. They now count the
-- files the list below them is actually showing, same template and same search.
--
-- ② There was no way to see rows without opening a file. The tab showed the published records and
-- nothing else, so a batch sitting in preview — everything not yet saved, which is precisely what
-- somebody wants to look through — was invisible from out here. Two files meant opening two files
-- and holding the comparison in your head.
--
-- This adds the reader for that: every staged row of a template, across all its files, filtered by
-- state, each row carrying the name of the file it came from.

-- ① The counters follow the tab.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_data_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$        'held', coalesce(sum(rows_held), 0))
        from qvm_new_apps.upload_batches b
       where v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)),$old$,
$new$        'held', coalesce(sum(rows_held), 0))
        from qvm_new_apps.upload_batches b
       where (p_template_key is null or b.template_key = p_template_key)
         and (p_status is null or b.status = p_status)
         and (p_search is null or b.file_name ilike '%' || p_search || '%'
              or coalesce(b.source_label,'') ilike '%' || p_search || '%')
         and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),$new$);
  if v_new = v_def then
    raise exception 'uploaded_data_get: the counters block was not found';
  end if;
  execute v_new;
end
$patch$;

-- ② Every staged row of one template, across every file that fed it.
--
-- Ordered newest file first and then by line number, because the question behind «show me the
-- rejected ones» is nearly always about the file just uploaded, and burying it under six months
-- of older imports answers a different question.
create or replace function qvm_new_apps.upload_rows_across_files(
  p_template_key text default null,
  p_state text default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_limit  integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_search text    := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'row_id', r.row_id, 'row_number', r.row_number,
               'batch_id', r.batch_id, 'file_name', r.file_name,
               'source_part_number', r.source_part_number,
               'clean_part_number', r.clean_part_number,
               'display_part_number', r.display_part_number,
               'clean_name', r.clean_name, 'source_name', r.source_name,
               'state', r.state, 'reason', r.reason, 'raw', r.raw)
             order by r.file_created_at desc, r.row_number)
        from (
          -- Named one by one rather than u.*: upload_rows carries its own created_at, and
          -- `u.*, b.created_at` would put two columns of that name in here — after which
          -- ordering by it is ambiguous and the function will not even compile.
          select u.row_id, u.row_number, u.batch_id, u.source_part_number,
                 u.clean_part_number, u.display_part_number,
                 u.clean_name, u.source_name, u.state, u.reason, u.raw,
                 b.file_name, b.created_at as file_created_at
            from qvm_new_apps.upload_rows u
            join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
           where (p_template_key is null or b.template_key = p_template_key)
             and (p_state is null or u.state = p_state)
             and (v_search is null
                  or u.source_part_number ilike '%' || v_search || '%'
                  or coalesce(u.clean_part_number, '') ilike '%' || v_search || '%'
                  or coalesce(u.clean_name, '') ilike '%' || v_search || '%'
                  or b.file_name ilike '%' || v_search || '%')
             and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))
           order by b.created_at desc, u.row_number
           limit v_limit offset greatest(coalesce(p_offset, 0), 0)
        ) r), '[]'::jsonb),

    'total', (
      select count(*)
        from qvm_new_apps.upload_rows u
        join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
       where (p_template_key is null or b.template_key = p_template_key)
         and (p_state is null or u.state = p_state)
         and (v_search is null
              or u.source_part_number ilike '%' || v_search || '%'
              or coalesce(u.clean_part_number, '') ilike '%' || v_search || '%'
              or coalesce(u.clean_name, '') ilike '%' || v_search || '%'
              or b.file_name ilike '%' || v_search || '%')
         and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)))
  ));
end
$function$;

revoke all on function qvm_new_apps.upload_rows_across_files(text, text, text, integer, integer) from public;
grant execute on function qvm_new_apps.upload_rows_across_files(text, text, text, integer, integer) to authenticated;

-- No index is added: upload_rows_by_state already covers (batch_id, state), which is what both
-- the filter and the join need. A second index differing only by a trailing row_number would be
-- one more thing to keep written on every staged row, for an ordering that happens after the
-- limit has already cut the set to a page.
