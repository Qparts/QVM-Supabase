-- Reading a file whose columns are the supplier's names, not ours.
--
-- A real 7,722-row purchase file was rejected in full — every row «missing a mandatory field» —
-- because it is headed `Item Name`, `Vendor Name`, `Bill Date`, `Item Total قبل الضريبة`, and the
-- reader looks its columns up by exact key. Not one row was actually bad. The template asks
-- people to rewrite their export before uploading it, which is work nobody should be doing by
-- hand for a file this size.
--
-- So the header gets the same treatment the values already have: a suggestion, a person's
-- confirmation, and a memory of the answer.
--
-- One correction here can only come from a person, and it matters more than the rest put
-- together: `Item Total قبل الضريبة` is the line total, and wholesale_price is a unit price. Read
-- straight across, the 2,880 rows in that file with a quantity above one would have been stored
-- at several times their real cost — landing successfully, with nothing to notice.

-- The file as the supplier wrote it, kept apart from the file as we agreed to read it.
alter table qvm_new_apps.upload_rows
  add column if not exists raw_source jsonb;

update qvm_new_apps.upload_rows set raw_source = raw where raw_source is null;

/** What a header means. Seeded from headers real files use, and editable, because the next
    supplier will invent a name nobody here thought of. */
create table if not exists qvm_new_apps.upload_column_aliases (
  alias_id     bigint generated always as identity primary key,
  target_key   text not null,
  norm_alias   text not null,
  sample_alias text,
  unique (target_key, norm_alias)
);
alter table qvm_new_apps.upload_column_aliases enable row level security;

/** The answer, remembered per template, so the same export maps itself next month. */
create table if not exists qvm_new_apps.upload_column_map (
  map_id        bigint generated always as identity primary key,
  template_key  text not null,
  norm_header   text not null,
  target_key    text,
  -- 'unit' or 'line_total'. A total is divided by the quantity before it is stored.
  basis         text,
  sample_header text,
  decided_by    uuid,
  decided_at    timestamptz not null default now(),
  unique (template_key, norm_header)
);
alter table qvm_new_apps.upload_column_map enable row level security;

insert into qvm_new_apps.upload_column_aliases (target_key, norm_alias, sample_alias)
select v.k, qvm_new_apps.norm_text(v.a), v.a from (values
  ('part_number','item name'), ('part_number','part number'), ('part_number','part no'),
  ('part_number','partno'), ('part_number','item code'), ('part_number','sku'),
  ('part_number','رقم القطعة'), ('part_number','رقم الصنف'), ('part_number','الصنف'),
  ('supplier_name','vendor name'), ('supplier_name','supplier'), ('supplier_name','supplier name'),
  ('supplier_name','المورد'), ('supplier_name','اسم المورد'), ('supplier_name','الوكيل'),
  ('city','vendor city'), ('city','المدينة'), ('city','مدينة المورد'),
  ('purchase_date','bill date'), ('purchase_date','invoice date'), ('purchase_date','date'),
  ('purchase_date','تاريخ الفاتورة'), ('purchase_date','التاريخ'), ('purchase_date','تاريخ الشراء'),
  ('wholesale_price','item total'), ('wholesale_price','unit price'), ('wholesale_price','price'),
  ('wholesale_price','cost'), ('wholesale_price','سعر الشراء'), ('wholesale_price','التكلفة'),
  ('wholesale_price','الاجمالي'), ('wholesale_price','item total قبل الضريبة'),
  ('qty','quantity'), ('qty','qty'), ('qty','الكمية'), ('qty','العدد'),
  ('name_ar','description'), ('name_ar','item description'), ('name_ar','الوصف'), ('name_ar','اسم القطعة'),
  ('name_en','english name'), ('name_en','name en'),
  ('retail_price','retail price'), ('retail_price','سعر البيع'),
  ('before_discount_price','before discount'), ('before_discount_price','السعر قبل الخصم'),
  ('make','make'), ('make','brand'), ('make','الماركة'), ('make','الموديل'),
  ('part_class','part class'), ('part_class','category'), ('part_class','النوع'), ('part_class','الفئة')
) v(k, a)
where not exists (select 1 from qvm_new_apps.upload_column_aliases);

/** What each header in a staged file most likely is, with the evidence for saying so. */
create or replace function qvm_new_apps.upload_batch_columns(p_batch_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare v_b record; v_cols jsonb; v_targets jsonb; v_missing jsonb;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  with headers as (
    -- Read from the pristine copy: once a map has been applied, `raw` carries our names and
    -- asking about those would be asking about our own answer.
    select distinct h.key as header
      from qvm_new_apps.upload_rows r,
           lateral jsonb_object_keys(coalesce(r.raw_source, r.raw)) h(key)
     where r.batch_id = p_batch_id
  ), samples as (
    select h.header,
           (select string_agg(distinct s.v, ' · ')
              from (select nullif(btrim(coalesce(r.raw_source, r.raw) ->> h.header), '') as v
                      from qvm_new_apps.upload_rows r
                     where r.batch_id = p_batch_id
                       and nullif(btrim(coalesce(r.raw_source, r.raw) ->> h.header), '') is not null
                     limit 3) s) as sample
      from headers h
  )
  select jsonb_agg(jsonb_build_object(
           'header', s.header,
           'sample', s.sample,
           'target_key', coalesce(m.target_key, a.target_key, f.target_key),
           'basis', m.basis,
           -- Where the suggestion came from: «we remembered» and «it looks like» are different
           -- claims, and only one of them was ever confirmed by a person.
           'via', case when m.target_key is not null then 'remembered'
                       when a.target_key is not null then 'known name'
                       when f.target_key is not null then 'similar name'
                       else null end,
           'score', f.s)
         order by s.header) into v_cols
    from samples s
    left join qvm_new_apps.upload_column_map m
           on m.template_key = v_b.template_key and m.norm_header = qvm_new_apps.norm_text(s.header)
    left join qvm_new_apps.upload_column_aliases a
           on a.norm_alias = qvm_new_apps.norm_text(s.header)
    left join lateral (
      select al.target_key, round(max(similarity(al.norm_alias, qvm_new_apps.norm_text(s.header)))::numeric, 3) as s
        from qvm_new_apps.upload_column_aliases al
       where similarity(al.norm_alias, qvm_new_apps.norm_text(s.header)) > 0.45
       group by al.target_key
       order by 2 desc limit 1
    ) f on true;

  select jsonb_agg(jsonb_build_object(
           'key', c->>'key', 'required', coalesce((c->>'required')::boolean, false)))
    into v_targets
    from qvm_new_apps.upload_templates t,
         lateral jsonb_array_elements(t.columns) c
   where t.template_key = v_b.template_key;

  select coalesce(jsonb_agg(x.key), '[]'::jsonb) into v_missing
    from (
      select c->>'key' as key
        from qvm_new_apps.upload_templates t, lateral jsonb_array_elements(t.columns) c
       where t.template_key = v_b.template_key
         and coalesce((c->>'required')::boolean, false)
    ) x
   where not exists (
     select 1 from jsonb_array_elements(coalesce(v_cols, '[]'::jsonb)) e
      where e->>'target_key' = x.key);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'template_key', v_b.template_key,
    'columns', coalesce(v_cols, '[]'::jsonb),
    'targets', coalesce(v_targets, '[]'::jsonb),
    'missing_required', v_missing,
    'mapped', (select count(*) from jsonb_array_elements(coalesce(v_cols,'[]'::jsonb)) e
                where e->>'target_key' is not null)));
end
$function$;

revoke all on function qvm_new_apps.upload_batch_columns(bigint) from public;
grant execute on function qvm_new_apps.upload_batch_columns(bigint) to authenticated;

/** Applies the confirmed map to the staged rows, and optionally splits the multi-part cells. */
create or replace function qvm_new_apps.upload_batch_apply_columns(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare
  v_batch bigint := (p_data->>'batch_id')::bigint;
  v_map jsonb := coalesce(p_data->'map', '[]'::jsonb);
  v_remember boolean := coalesce((p_data->>'remember')::boolean, true);
  v_split boolean := coalesce((p_data->>'split_multi')::boolean, false);
  v_b record; m jsonb; v_qty_header text; v_pn_header text;
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

  if v_remember then
    for m in select * from jsonb_array_elements(v_map) loop
      insert into qvm_new_apps.upload_column_map
        (template_key, norm_header, target_key, basis, sample_header, decided_by)
      values (v_b.template_key, qvm_new_apps.norm_text(m->>'header'),
              nullif(m->>'target_key',''), nullif(m->>'basis',''), m->>'header', auth.uid())
      on conflict (template_key, norm_header) do update set
        target_key = excluded.target_key, basis = excluded.basis,
        sample_header = excluded.sample_header, decided_by = excluded.decided_by,
        decided_at = now();
    end loop;
  end if;

  -- `raw` is rebuilt from the pristine copy every time, so re-answering a column replaces the
  -- previous answer rather than layering on top of it.
  update qvm_new_apps.upload_rows r
     set raw = (
       select coalesce(jsonb_object_agg(t.key, t.val) filter (where t.val is not null), '{}'::jsonb)
         from (
           select e->>'target_key' as key,
                  case
                    when e->>'basis' = 'line_total'
                     and qvm_new_apps.norm_number(coalesce(r.raw_source, r.raw) ->> (e->>'header')) is not null
                     and coalesce(qvm_new_apps.norm_number(coalesce(r.raw_source, r.raw) ->> v_qty_header), 0) > 0
                    -- The column is the whole line, so the unit price is what it divides into.
                    then round(qvm_new_apps.norm_number(coalesce(r.raw_source, r.raw) ->> (e->>'header'))
                               / qvm_new_apps.norm_number(coalesce(r.raw_source, r.raw) ->> v_qty_header), 4)::text
                    else nullif(btrim(coalesce(coalesce(r.raw_source, r.raw) ->> (e->>'header'), '')), '')
                  end as val
             from jsonb_array_elements(v_map) e
            where nullif(e->>'target_key','') is not null
         ) t)
   where r.batch_id = v_batch;

  -- One cell naming two parts is two purchases. Split only where the quantity divides evenly
  -- between them; anything else is a guess about who bought how many of which, and is left for
  -- a person to settle from the problem file.
  if v_split and v_pn_header is not null then
    select coalesce(max(row_number), 0) into v_next
      from qvm_new_apps.upload_rows where batch_id = v_batch;

    with multi as (
      select r.row_id, r.row_number, r.raw, r.raw_source,
             regexp_split_to_array(r.raw->>'part_number', '\s*\+\s*') as parts,
             qvm_new_apps.norm_number(r.raw->>'qty') as qty
        from qvm_new_apps.upload_rows r
       where r.batch_id = v_batch and r.raw->>'part_number' ~ '\+'
    ), splittable as (
      select * from multi
       where array_length(parts, 1) > 1
         and (qty is null or qty = 0 or mod(qty::numeric, array_length(parts,1)::numeric) = 0)
    ), expanded as (
      select s.row_id, s.raw, s.raw_source, p.part, p.ord,
             case when s.qty is null or s.qty = 0 then s.raw->>'qty'
                  else (s.qty / array_length(s.parts,1))::text end as new_qty
        from splittable s, unnest(s.parts) with ordinality p(part, ord)
    )
    insert into qvm_new_apps.upload_rows
      (batch_id, row_number, raw, raw_source, source_part_number, state, reason)
    select v_batch, v_next + row_number() over (order by e.row_id, e.ord),
           e.raw || jsonb_build_object('part_number', btrim(e.part), 'qty', e.new_qty),
           e.raw_source, btrim(e.part), 'ready',
           'split from a cell naming ' || (select count(*) from expanded x where x.row_id = e.row_id) || ' parts'
      from expanded e;
    get diagnostics v_split_done = row_count;

    delete from qvm_new_apps.upload_rows r
     where r.batch_id = v_batch and r.raw->>'part_number' ~ '\+'
       and r.row_id in (select row_id from qvm_new_apps.upload_rows r2
                         where r2.batch_id = v_batch and r2.raw->>'part_number' ~ '\+'
                           and array_length(regexp_split_to_array(r2.raw->>'part_number', '\s*\+\s*'), 1) > 1
                           and (qvm_new_apps.norm_number(r2.raw->>'qty') is null
                                or qvm_new_apps.norm_number(r2.raw->>'qty') = 0
                                or mod(qvm_new_apps.norm_number(r2.raw->>'qty')::numeric,
                                       array_length(regexp_split_to_array(r2.raw->>'part_number', '\s*\+\s*'),1)::numeric) = 0));
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

revoke all on function qvm_new_apps.upload_batch_apply_columns(jsonb) from public;
grant execute on function qvm_new_apps.upload_batch_apply_columns(jsonb) to authenticated;
