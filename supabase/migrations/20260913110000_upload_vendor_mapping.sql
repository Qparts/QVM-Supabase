-- Asking who a supplier is, once, instead of filing them under whatever was typed.
--
-- part_purchase_history.supplier_name is free text with no link to a vendor, and the duplicate
-- check in upload_batch_write_rows compared that text exactly. So «قمة النظائر» and
-- «قمه النظائر» were two suppliers, both got written, and the vendor price comparison the Past
-- Purchases screen exists to produce was wrong with nobody able to see why.
--
-- The shape follows upload_code_rules, which already works this way: a question asked once,
-- answered once, and applied to every file afterwards. The difference is scope. A part code
-- means different things from different suppliers, so those rules are per-source. A company
-- name is the same company whoever typed it, so these are global.

create table if not exists qvm_new_apps.upload_value_mappings (
  mapping_id   bigint generated always as identity primary key,
  field        text not null,
  -- The folded form is the key: that is what makes the second spelling find the first answer.
  norm_value   text not null,
  sample_raw   text,
  target_kind  text not null check (target_kind in ('vendor','ignore')),
  target_id    integer,
  target_label text,
  confidence   numeric(5,4),
  auto         boolean not null default false,
  decided_by   uuid,
  decided_at   timestamptz not null default now(),
  unique (field, norm_value)
);

alter table qvm_new_apps.upload_value_mappings enable row level security;

-- The history row can finally name the vendor rather than only quoting the text someone typed.
alter table qvm_new_apps.part_purchase_history
  add column if not exists vendor_id integer references qvm_new_apps.vendors(vendor_id);

create index if not exists part_purchase_history_vendor_idx
  on qvm_new_apps.part_purchase_history (vendor_id);

/**
 * What a typed supplier name means — and, when it is unsure, what it considered.
 *
 * Order matters. A decision already recorded wins outright, which is why the same file from the
 * same supplier only ever asks once. Then an exact match once folded, which is where «قمة» and
 * «قمه» meet. Only then does similarity get a say.
 */
create or replace function qvm_new_apps.vendor_match(p_raw text)
returns table (
  status text, vendor_id integer, vendor_name text, score numeric,
  runner_up_score numeric, candidates jsonb)
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare
  v_norm text := qvm_new_apps.norm_text(p_raw);
  v_map record; v_best record; v_second numeric; v_cands jsonb;
begin
  if v_norm is null then
    return query select 'empty'::text, null::integer, null::text, null::numeric, null::numeric, '[]'::jsonb;
    return;
  end if;

  select * into v_map from qvm_new_apps.upload_value_mappings m
   where m.field = 'supplier_name' and m.norm_value = v_norm;
  if found then
    return query select
      case when v_map.target_kind = 'ignore' then 'ignored' else 'mapped' end,
      v_map.target_id, v_map.target_label, 1.0::numeric, null::numeric, '[]'::jsonb;
    return;
  end if;

  select v.vendor_id, coalesce(v.vendor_name, v.zoho_name) as nm into v_best
    from qvm_new_apps.vendors v
   where qvm_new_apps.norm_text(coalesce(v.vendor_name, v.zoho_name)) = v_norm
   order by v.vendor_id limit 1;
  if found then
    return query select 'matched'::text, v_best.vendor_id, v_best.nm, 1.0::numeric, null::numeric, '[]'::jsonb;
    return;
  end if;

  select jsonb_agg(jsonb_build_object(
           'vendor_id', c.vendor_id, 'vendor_name', c.nm, 'score', round(c.s, 3))
         order by c.s desc)
    into v_cands
    from (
      select v.vendor_id, coalesce(v.vendor_name, v.zoho_name) as nm,
             similarity(qvm_new_apps.norm_text(coalesce(v.vendor_name, v.zoho_name)), v_norm)::numeric as s
        from qvm_new_apps.vendors v
       where coalesce(v.vendor_name, v.zoho_name) is not null
       order by s desc limit 5
    ) c
   where c.s > 0.15;

  select (c->>'vendor_id')::integer as vendor_id, c->>'vendor_name' as nm, (c->>'score')::numeric as s
    into v_best
    from jsonb_array_elements(coalesce(v_cands, '[]'::jsonb)) c limit 1;

  select (c->>'score')::numeric into v_second
    from jsonb_array_elements(coalesce(v_cands, '[]'::jsonb)) with ordinality t(c, i)
   where t.i = 2;

  if v_best.vendor_id is null then
    return query select 'unknown'::text, null::integer, null::text, null::numeric, null::numeric,
                        coalesce(v_cands, '[]'::jsonb);
    return;
  end if;

  -- Accepted on its own only when it is both close AND clearly ahead of the next name. A
  -- threshold alone would happily choose between «وكالة بيترومين نيسان» and
  -- «( Wholesale ) وكالة بيترومين نيسان» — two real, different vendors on this list.
  if v_best.s >= 0.90 and (v_second is null or v_best.s - v_second >= 0.15) then
    return query select 'auto'::text, v_best.vendor_id, v_best.nm, v_best.s, v_second, v_cands;
  else
    return query select 'unknown'::text, null::integer, null::text, v_best.s, v_second, v_cands;
  end if;
end
$function$;

/** Everything in one staged file that still needs a person, grouped by name rather than by row. */
create or replace function qvm_new_apps.upload_batch_unresolved(p_batch_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare v_b record; v_rows jsonb;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  -- Only Past Purchases carries the supplier as text in the file; the other two are uploaded
  -- against a vendor chosen on the form, so there is nothing here to reconcile.
  if v_b.template_key <> 'past_purchases' then
    return jsonb_build_object('status', true, 'message', 'ok',
      'data', jsonb_build_object('field', null, 'values', '[]'::jsonb));
  end if;

  -- Once per distinct name: fifty rows from one misspelt supplier are one question, and
  -- answering it moves all fifty.
  select coalesce(jsonb_agg(x order by x.rows desc, x.raw), '[]'::jsonb) into v_rows from (
    select g.raw, g.rows, m.status, m.vendor_id, m.vendor_name, m.score, m.candidates
      from (
        select qvm_new_apps.upload_raw_get(r.raw, 'supplier_name') as raw, count(*) as rows
          from qvm_new_apps.upload_rows r
         where r.batch_id = p_batch_id
           and qvm_new_apps.upload_raw_get(r.raw, 'supplier_name') is not null
         group by 1
      ) g
      cross join lateral qvm_new_apps.vendor_match(g.raw) m
  ) x;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'field', 'supplier_name',
    'values', v_rows,
    'unknown', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'unknown'),
    'auto',    (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'auto')));
end
$function$;

revoke all on function qvm_new_apps.upload_batch_unresolved(bigint) from public;
grant execute on function qvm_new_apps.upload_batch_unresolved(bigint) to authenticated;

/** Recording the answer — and, only for the team, minting the vendor it refers to. */
create or replace function qvm_new_apps.upload_mapping_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare
  v_raw   text := nullif(btrim(coalesce(p_data->>'raw','')), '');
  v_kind  text := coalesce(nullif(btrim(coalesce(p_data->>'target_kind','')), ''), 'vendor');
  v_id    integer := nullif(p_data->>'target_id','')::integer;
  v_new   text := nullif(btrim(coalesce(p_data->>'new_vendor_name','')), '');
  v_conf  numeric := nullif(p_data->>'confidence','')::numeric;
  v_auto  boolean := coalesce((p_data->>'auto')::boolean, false);
  v_norm  text; v_label text;
begin
  -- A vendor who uploads their own file must not be able to invent vendors.
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  v_norm := qvm_new_apps.norm_text(v_raw);
  if v_norm is null then
    return jsonb_build_object('status', false, 'message', 'لا يوجد اسم لربطه', 'data', null);
  end if;

  if v_kind = 'vendor' then
    if v_id is null then
      if v_new is null then
        return jsonb_build_object('status', false,
          'message', 'اختر مورّداً موجوداً أو اكتب اسم مورّد جديد', 'data', null);
      end if;
      -- The same name folded is the same vendor. Creating a second one here would be this
      -- feature causing precisely the duplicate it was written to prevent.
      select v.vendor_id into v_id from qvm_new_apps.vendors v
       where qvm_new_apps.norm_text(coalesce(v.vendor_name, v.zoho_name)) = qvm_new_apps.norm_text(v_new)
       limit 1;
      if v_id is null then
        insert into qvm_new_apps.vendors (vendor_name, created_at, updated_at)
        values (v_new, now(), now())
        returning vendor_id into v_id;
      end if;
    end if;
    select coalesce(v.vendor_name, v.zoho_name) into v_label
      from qvm_new_apps.vendors v where v.vendor_id = v_id;
    if v_label is null then
      return jsonb_build_object('status', false, 'message', 'المورّد غير موجود', 'data', null);
    end if;
  else
    v_id := null; v_label := null;
  end if;

  insert into qvm_new_apps.upload_value_mappings
    (field, norm_value, sample_raw, target_kind, target_id, target_label, confidence, auto, decided_by)
  values ('supplier_name', v_norm, v_raw, v_kind, v_id, v_label, v_conf, v_auto, auth.uid())
  on conflict (field, norm_value) do update set
    sample_raw = excluded.sample_raw, target_kind = excluded.target_kind,
    target_id = excluded.target_id, target_label = excluded.target_label,
    confidence = excluded.confidence, auto = excluded.auto,
    decided_by = excluded.decided_by, decided_at = now();

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('vendor_id', v_id, 'vendor_name', v_label, 'kind', v_kind));
end
$function$;

revoke all on function qvm_new_apps.upload_mapping_save(jsonb) from public;
grant execute on function qvm_new_apps.upload_mapping_save(jsonb) to authenticated;

-- The Past Purchases branch of the writer, rewritten to resolve the vendor and to de-duplicate
-- twice. Patched in place because the rest of the function serves six other templates that are
-- not changing, and retyping them is how one picks up an edit nobody asked for.
do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_write_rows(bigint)'::regprocedure);
  v_start int; v_end int; v_old text; v_new text;
begin
  if position('dedup_in_file' in v_def) > 0 then return; end if;

  v_start := position('  elsif v_b.template_key = ''past_purchases'' then' in v_def);
  if v_start = 0 then raise exception 'past_purchases block not found'; end if;
  v_end := position('  elsif v_b.template_key = ''aliases'' then' in v_def);
  if v_end = 0 then raise exception 'aliases block not found'; end if;
  v_old := substring(v_def from v_start for v_end - v_start);

  v_new := '  elsif v_b.template_key = ''past_purchases'' then
    -- The supplier is resolved to a real vendor rather than filed under whatever was typed, and
    -- numbers and dates go through the shared normalisers — so «١٬٢٣٤٫٥٠» and «1,234.50» are one
    -- price and a spreadsheet serial is a date.
    --
    -- Two passes of de-duplication, because they catch different things. `not exists` compares
    -- against what is already stored, and cannot see rows being written by its own statement —
    -- so a file listing the same purchase twice under two spellings of the supplier wrote it
    -- twice, which is the duplicate this whole feature exists to stop. `distinct on` settles
    -- that within the file first, on the resolved vendor rather than the raw text.
    with src as (
      select r.row_number, r.source_part_number, r.clean_part_number, r.brand, r.part_class,
             r.raw, br.id as branch_id,
             m.vendor_id, m.vendor_name, m.status as match_status,
             qvm_new_apps.upload_raw_get(r.raw, ''supplier_name'') as v_supplier,
             qvm_new_apps.upload_raw_get(r.raw, ''city'') as v_city,
             qvm_new_apps.norm_number(r.raw->>''wholesale_price'')::double precision as v_cost,
             qvm_new_apps.norm_date(r.raw->>''purchase_date'') as v_date
        from qvm_new_apps.upload_rows r
        cross join unnest(v_branches) as br(id)
        cross join lateral qvm_new_apps.vendor_match(
                     qvm_new_apps.upload_raw_get(r.raw, ''supplier_name'')) m
       where r.batch_id = p_batch_id and r.state = ''ready''
         -- A name somebody chose to drop takes its rows with it.
         and m.status <> ''ignored''
    ), dedup_in_file as (
      select distinct on (
               s.clean_part_number, s.branch_id,
               coalesce(s.vendor_id::text, qvm_new_apps.norm_text(s.v_supplier)),
               qvm_new_apps.norm_text(s.v_city), s.v_date, s.v_cost) s.*
        from src s
       order by s.clean_part_number, s.branch_id,
                coalesce(s.vendor_id::text, qvm_new_apps.norm_text(s.v_supplier)),
                qvm_new_apps.norm_text(s.v_city), s.v_date, s.v_cost, s.row_number
    )
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, cost, retail_price, before_discount_price,
       cost_on, source_cost_date,
       supplier_name, vendor_id, city, qty, brand, brand_class, origin, client_branch_id, batch_id)
    select d.source_part_number, d.clean_part_number, d.v_cost,
           qvm_new_apps.norm_number(d.raw->>''retail_price''),
           qvm_new_apps.norm_number(d.raw->>''before_discount_price''),
           d.v_date, d.raw->>''purchase_date'',
           coalesce(d.vendor_name, d.v_supplier), d.vendor_id, d.v_city,
           qvm_new_apps.norm_number(d.raw->>''qty'')::integer,
           d.brand, d.part_class, ''external_excel'', d.branch_id, v_b.batch_id
      from dedup_in_file d
     where not exists (
       select 1 from qvm_new_apps.part_purchase_history h
        where h.clean_part_number = d.clean_part_number
          and h.client_branch_id is not distinct from d.branch_id
          and (h.vendor_id is not distinct from d.vendor_id
               or qvm_new_apps.norm_text(h.supplier_name)
                  is not distinct from qvm_new_apps.norm_text(d.v_supplier))
          and qvm_new_apps.norm_text(h.city) is not distinct from qvm_new_apps.norm_text(d.v_city)
          and h.cost_on is not distinct from d.v_date
          and h.cost is not distinct from d.v_cost);
    get diagnostics v_written = row_count;

';
  execute replace(v_def, v_old, v_new);
end
$mig$;
