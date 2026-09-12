-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.get_partfinder_report(
  p_from timestamptz default null, p_to timestamptz default null, p_employee uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_from timestamptz := coalesce(p_from, '2000-01-01'::timestamptz);
  v_to   timestamptz := coalesce(p_to,   now());
  v_total_extracted int; v_with_extractor int;
  v_manual_total int; v_volume jsonb; v_time jsonb; v_quality jsonb;
  v_flagged int; v_by_source jsonb; v_by_emp jsonb; v_by_brand jsonb;
  v_cannot int; v_unclear int; v_late int;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;

  create temporary table _base on commit drop as
  select qi.quotation_item_id, qi.main_brand, qi.extracted_by, qi.extracted_at,
         qi.created_at, qi.extraction_status, qi.quotation_id,
         not exists (select 1 from qvm_new_apps.quotation_vendor_items qv
                      where qv.quotation_item_id = qi.quotation_item_id and qv.from_database is true) AS is_manual
  from qvm_new_apps.quotation_items qi
  where qi.part_number is not null and btrim(qi.part_number) <> ''
    and qi.created_at >= v_from and qi.created_at <= v_to
    and (p_employee is null or qi.extracted_by = p_employee);

  select count(*), count(*) filter (where extracted_by is not null)
    into v_total_extracted, v_with_extractor from _base;

  select (select count(*) from _base where is_manual),
    coalesce(jsonb_agg(jsonb_build_object('user_id', t.extracted_by, 'user_name', ud.user_name,
       'role', rl.list_data, 'city', cb.city, 'count', t.c,
       'contribution_pct', case when (select count(*) from _base where is_manual)>0
          then round(100.0*t.c/(select count(*) from _base where is_manual),1) else null end)
       order by t.c desc), '[]'::jsonb)
  into v_manual_total, v_volume
  from (select extracted_by, count(*) AS c from _base where is_manual group by extracted_by) t
  left join qvm_new_apps.user_data ud on ud.user_id = t.extracted_by
  left join qvm_new_apps.list_data rl on rl.list_data_id = ud.user_role
  left join qvm_new_apps.client_branches cb on cb.customer_id = ud.user_branch;

  select jsonb_build_object(
    'avg_business_minutes', coalesce(round(avg(bmin),1),0),
    'sample_count', count(*),
    'by_employee', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', x.extracted_by, 'user_name', x.user_name,
               'avg_business_minutes', x.avg_bmin, 'items', x.items) order by x.avg_bmin)
      from (select s.extracted_by, ud.user_name, round(avg(s.bmin),1) AS avg_bmin, count(*) AS items
            from (select b.extracted_by, qvm_new_apps.business_minutes(b.created_at, b.extracted_at) AS bmin
                  from _base b
                  where b.extracted_at is not null and b.extracted_at > b.created_at
                    and coalesce(b.extraction_status,'') <> 'unclear') s
            left join qvm_new_apps.user_data ud on ud.user_id = s.extracted_by
            group by s.extracted_by, ud.user_name) x), '[]'::jsonb)
  ) into v_time
  from (select qvm_new_apps.business_minutes(b.created_at, b.extracted_at) AS bmin
        from _base b
        where b.extracted_at is not null and b.extracted_at > b.created_at
          and coalesce(b.extraction_status,'') <> 'unclear') z;

  create temporary table _flags on commit drop as
  select distinct f.quotation_item_id, f.src
  from (
    select qi.quotation_item_id, 'rfq_cancel'::text AS src
      from qvm_new_apps.quotation_items qi where qi.cancellation_reason = 196
    union all
    select ci.quotation_item_id, 'post_confirm'
      from qvm_new_apps.confirmed_items ci where ci.cancellation_reason = 196
    union all
    select ci.quotation_item_id, 'return'
      from qvm_new_apps.return_issues ri
      join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = ri.confirmed_item_id
      where ri.return_reasons = 136
    union all
    select ci.quotation_item_id, 'return'
      from qvm_new_apps.returned_issues ri
      join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = ri.confirmed_item_id
      where ri.return_reason = 136
    union all
    select ci.quotation_item_id, 'creditnote'
      from qvm_new_apps.creditnote_items cn
      join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = cn.confirmed_item_id
      where cn.return_reason = 136
  ) f
  join _base b on b.quotation_item_id = f.quotation_item_id;

  select count(distinct quotation_item_id) into v_flagged from _flags;

  select coalesce(jsonb_agg(jsonb_build_object('source', src, 'count', c) order by c desc), '[]'::jsonb)
    into v_by_source
  from (select src, count(distinct quotation_item_id) AS c from _flags group by src) s;

  select coalesce(jsonb_agg(jsonb_build_object('user_id', e.extracted_by, 'user_name', ud.user_name,
      'flagged', e.flagged, 'extracted', e.extracted,
      'error_pct', case when e.extracted>0 then round(100.0*e.flagged/e.extracted,1) else 0 end) order by e.flagged desc), '[]'::jsonb)
    into v_by_emp
  from (
    select b.extracted_by,
           count(distinct b.quotation_item_id) filter (where fl.quotation_item_id is not null) AS flagged,
           count(distinct b.quotation_item_id) AS extracted
    from _base b left join (select distinct quotation_item_id from _flags) fl on fl.quotation_item_id = b.quotation_item_id
    group by b.extracted_by
  ) e left join qvm_new_apps.user_data ud on ud.user_id = e.extracted_by;

  select coalesce(jsonb_agg(jsonb_build_object('brand', bd.list_data, 'flagged', g.flagged, 'total', g.total) order by g.flagged desc, g.total desc), '[]'::jsonb)
    into v_by_brand
  from (
    select b.main_brand,
           count(distinct b.quotation_item_id) filter (where fl.quotation_item_id is not null) AS flagged,
           count(distinct b.quotation_item_id) AS total
    from _base b left join (select distinct quotation_item_id from _flags) fl on fl.quotation_item_id = b.quotation_item_id
    group by b.main_brand
  ) g left join qvm_new_apps.list_data bd on bd.list_data_id = g.main_brand;

  select count(*) filter (where extraction_status = 'cannot_extract'),
         count(*) filter (where extraction_status = 'unclear')
    into v_cannot, v_unclear from _base;

  select count(*) into v_late
  from _base b join qvm_new_apps.quotations q on q.quotation_id = b.quotation_id
  where b.created_at > q.created_at + interval '1 hour';

  v_quality := jsonb_build_object(
    'error_rate_pct', case when v_total_extracted>0 then round(100.0*v_flagged/v_total_extracted,1) else 0 end,
    'flagged_count', v_flagged, 'total_extracted', v_total_extracted,
    'by_source', v_by_source, 'by_employee', v_by_emp, 'by_brand', v_by_brand,
    'cannot_extract_count', v_cannot, 'unclear_count', v_unclear, 'late_additions', v_late);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'data_dependency', jsonb_build_object(
       'part_numbered_total', v_total_extracted, 'with_extractor', v_with_extractor,
       'coverage_pct', case when v_total_extracted>0 then round(100.0*v_with_extractor/v_total_extracted,1) else 0 end),
    'volume', jsonb_build_object('total_manual', v_manual_total, 'by_employee', v_volume),
    'time', v_time,
    'financial', jsonb_build_object('note', 'Not directly applicable to this role'),
    'quality', v_quality
  ));
end; $$;

notify pgrst, 'reload schema';
