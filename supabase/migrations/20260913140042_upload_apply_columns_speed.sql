-- Applying a column map to a real file, inside the time a request is allowed to take.
--
-- The first version worked and was tested — as `postgres`, which has no statement timeout. Run
-- from the app as `authenticated`, which does, the 7,722-row file died on «canceling statement
-- due to statement timeout» and the person was left with a screen full of red and a file that
-- still would not import. Testing it in a context without the limit is what hid that.
--
-- Two separate problems, and only one of them was the limit.
--
-- The rewrite itself was 15 seconds. An attempt to speed it up by joining the map instead of
-- re-expanding it per row made it 18: the join multiplies each row's whole JSON document by the
-- number of columns, and copying 54,000 documents costs more than the arithmetic ever did.
-- Building one expression per row with the map baked in — it is known by then — is 2.9s. The
-- headers come from the uploaded file, so each one goes in through %L.
--
-- The remaining 11 seconds are the cleanup pass itself, which is the actual work. So the limit
-- is also raised, for this function alone: eight seconds is sized for a request that serves one
-- screen, not for re-reading a file of this size, and enforcing it here only means the file
-- stays broken.

create or replace function qvm_new_apps.upload_batch_apply_columns(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
set statement_timeout to '180s'
as $function$
declare
  v_batch bigint := (p_data->>'batch_id')::bigint;
  v_map jsonb := coalesce(p_data->'map', '[]'::jsonb);
  v_remember boolean := coalesce((p_data->>'remember')::boolean, true);
  v_split boolean := coalesce((p_data->>'split_multi')::boolean, false);
  v_b record; m record; v_qty_header text; v_pn_header text; v_price_header text;
  v_parts text[] := '{}'; v_sql text;
  v_split_done integer := 0; v_split_left integer := 0; v_next integer;
begin
  if not qvm_new_apps.may_touch_upload_batch(v_batch) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = v_batch;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_b.status = 'published' then
    return jsonb_build_object('status', false, 'message', 'الدفعة منشورة بالفعل', 'data', null);
  end if;

  select e->>'header' into v_qty_header from jsonb_array_elements(v_map) e
   where e->>'target_key' = 'qty' limit 1;
  select e->>'header' into v_pn_header from jsonb_array_elements(v_map) e
   where e->>'target_key' = 'part_number' limit 1;
  select e->>'header' into v_price_header from jsonb_array_elements(v_map) e
   where e->>'basis' = 'line_total' limit 1;

  if v_remember then
    for m in select e->>'header' h, e->>'target_key' k, e->>'basis' b
               from jsonb_array_elements(v_map) e loop
      insert into qvm_new_apps.upload_column_map
        (template_key, norm_header, target_key, basis, sample_header, decided_by)
      values (v_b.template_key, qvm_new_apps.norm_text(m.h),
              nullif(m.k,''), nullif(m.b,''), m.h, auth.uid())
      on conflict (template_key, norm_header) do update set
        target_key = excluded.target_key, basis = excluded.basis,
        sample_header = excluded.sample_header, decided_by = excluded.decided_by,
        decided_at = now();
    end loop;
  end if;

  for m in select e->>'header' h, e->>'target_key' k, e->>'basis' b
             from jsonb_array_elements(v_map) e
            where nullif(e->>'target_key','') is not null loop
    if m.b = 'line_total' then
      -- The column is the whole line, so the unit price is what it divides into.
      v_parts := v_parts || format(
        '%L, case when v.qty > 0 and v.price is not null then round(v.price / v.qty, 4)::text '
        || 'else nullif(btrim(coalesce(d.doc->>%L, '''')), '''') end', m.k, m.h);
    else
      v_parts := v_parts || format('%L, nullif(btrim(coalesce(d.doc->>%L, '''')), '''')', m.k, m.h);
    end if;
  end loop;

  if array_length(v_parts, 1) > 0 then
    -- `raw` is rebuilt from the pristine copy every time, so re-answering a column replaces the
    -- earlier answer rather than layering over it. The two normalisers run once per row each,
    -- in the lateral, instead of once per mention.
    v_sql := format($q$
      update qvm_new_apps.upload_rows r set raw = (
        select jsonb_strip_nulls(jsonb_build_object(%s))
          from (select coalesce(r.raw_source, r.raw) as doc) d,
               lateral (select qvm_new_apps.norm_number(d.doc->>%L) as qty,
                               qvm_new_apps.norm_number(d.doc->>%L) as price) v)
       where r.batch_id = %s $q$,
      array_to_string(v_parts, ', '), v_qty_header, v_price_header, v_batch);
    execute v_sql;
  end if;

  if v_split and v_pn_header is not null then
    select coalesce(max(row_number), 0) into v_next
      from qvm_new_apps.upload_rows where batch_id = v_batch;

    -- Decided once and kept, so the insert and the delete cannot disagree about which rows were
    -- splittable — re-deriving that inside the delete meant scanning the same table again for
    -- every row it examined.
    create temporary table _split_rows on commit drop as
    select r.row_id, r.raw, r.raw_source,
           regexp_split_to_array(r.raw->>'part_number', '\s*\+\s*') as parts,
           qvm_new_apps.norm_number(r.raw->>'qty') as qty
      from qvm_new_apps.upload_rows r
     where r.batch_id = v_batch
       and r.raw->>'part_number' ~ '\+'
       and array_length(regexp_split_to_array(r.raw->>'part_number', '\s*\+\s*'), 1) > 1
       and (qvm_new_apps.norm_number(r.raw->>'qty') is null
            or qvm_new_apps.norm_number(r.raw->>'qty') = 0
            or mod(qvm_new_apps.norm_number(r.raw->>'qty')::numeric,
                   array_length(regexp_split_to_array(r.raw->>'part_number', '\s*\+\s*'),1)::numeric) = 0);

    insert into qvm_new_apps.upload_rows
      (batch_id, row_number, raw, raw_source, source_part_number, state, reason)
    select v_batch, v_next + row_number() over (order by e.row_id, e.ord),
           e.raw || jsonb_build_object('part_number', btrim(e.part), 'qty', e.new_qty),
           e.raw_source, btrim(e.part), 'ready',
           'split from a cell naming ' || array_length(e.parts, 1) || ' parts'
      from (
        select s.row_id, s.raw, s.raw_source, s.parts, p.part, p.ord,
               case when s.qty is null or s.qty = 0 then s.raw->>'qty'
                    else (s.qty / array_length(s.parts,1))::text end as new_qty
          from _split_rows s, unnest(s.parts) with ordinality p(part, ord)
      ) e;
    get diagnostics v_split_done = row_count;

    delete from qvm_new_apps.upload_rows r using _split_rows s where r.row_id = s.row_id;
  end if;

  select count(*) into v_split_left from qvm_new_apps.upload_rows
   where batch_id = v_batch and raw->>'part_number' ~ '\+';

  perform qvm_new_apps.upload_batch_recompute(v_batch);
  select * into v_b from qvm_new_apps.upload_batches where batch_id = v_batch;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows_total', v_b.rows_total, 'rows_ready', v_b.rows_ready,
    'rows_rejected', v_b.rows_rejected, 'rows_disabled', v_b.rows_disabled,
    'split_created', v_split_done, 'multi_part_left', v_split_left));
end
$function$;
