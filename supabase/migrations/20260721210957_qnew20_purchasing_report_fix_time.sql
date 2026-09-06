-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.get_purchasing_report(
  p_from timestamptz default null,
  p_to   timestamptz default null,
  p_employee uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_from timestamptz := coalesce(p_from, '2000-01-01'::timestamptz);
  v_to   timestamptz := coalesce(p_to,   now());
  v_volume jsonb; v_time jsonb; v_financial jsonb; v_quality jsonb;
  v_total_items int; v_total_pos int;
  v_r1 jsonb; v_r2 jsonb; v_r3 jsonb;
  v_raw_pct numeric; v_adj_pct numeric;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;

  with priced as (
    select qi.created_by, count(*)::int AS items_priced
    from qvm_new_apps.quotation_items qi
    where qi.price_before_vat is not null
      and qi.created_at >= v_from and qi.created_at <= v_to
      and (p_employee is null or qi.created_by = p_employee)
    group by qi.created_by
  ),
  pos as (
    select po.created_by, count(*)::int AS pos_issued
    from qvm_new_apps.purchase_orders po
    where po.created_at >= v_from and po.created_at <= v_to
      and (p_employee is null or po.created_by = p_employee)
    group by po.created_by
  ),
  emp as (
    select coalesce(pr.created_by, po.created_by) AS user_id,
           coalesce(pr.items_priced,0) AS items_priced,
           coalesce(po.pos_issued,0)   AS pos_issued
    from priced pr full outer join pos po on po.created_by = pr.created_by
  ),
  tot as (select nullif(sum(items_priced),0) AS t_items from emp)
  select
    (select coalesce(sum(items_priced),0)::int from emp),
    (select coalesce(sum(pos_issued),0)::int from emp),
    coalesce(jsonb_agg(jsonb_build_object(
       'user_id', e.user_id, 'user_name', ud.user_name, 'role', rl.list_data, 'city', cb.city,
       'items_priced', e.items_priced, 'pos_issued', e.pos_issued,
       'contribution_pct', round(100.0 * e.items_priced / (select t_items from tot), 1)
     ) order by e.items_priced desc), '[]'::jsonb)
  into v_total_items, v_total_pos, v_volume
  from emp e
  left join qvm_new_apps.user_data ud on ud.user_id = e.user_id
  left join qvm_new_apps.list_data rl on rl.list_data_id = ud.user_role
  left join qvm_new_apps.client_branches cb on cb.customer_id = ud.user_branch;

  with firstcost as (
    select qvi.quotation_item_id, min(cl.created_at) AS first_priced_at
    from qvm_new_apps.cost_logs cl
    join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = cl.cost_id
    group by qvi.quotation_item_id
  ),
  spans as (
    select qi.created_by,
           qvm_new_apps.business_minutes(qi.created_at, fc.first_priced_at) AS bmin
    from qvm_new_apps.quotation_items qi
    join firstcost fc on fc.quotation_item_id = qi.quotation_item_id
    where fc.first_priced_at > qi.created_at
      and qi.created_at >= v_from and qi.created_at <= v_to
      and (p_employee is null or qi.created_by = p_employee)
  )
  select jsonb_build_object(
    'avg_business_minutes', coalesce(round(avg(bmin),1),0),
    'sample_count', count(*),
    'by_employee', coalesce((
       select jsonb_agg(jsonb_build_object(
         'user_id', x.created_by, 'user_name', x.user_name,
         'avg_business_minutes', x.avg_bmin, 'items', x.items) order by x.avg_bmin)
       from (
         select s2.created_by, ud.user_name, round(avg(s2.bmin),1) AS avg_bmin, count(*) AS items
         from spans s2 left join qvm_new_apps.user_data ud on ud.user_id = s2.created_by
         group by s2.created_by, ud.user_name
       ) x), '[]'::jsonb)
  ) into v_time from spans;

  create temporary table _pp on commit drop as
  select
    pi.purchase_item_id, qi.quotation_item_id, qi.quotation_id,
    coalesce(ci.final_part_number, qi.part_number) AS part_number,
    qvm_new_apps.brand_type_bucket(coalesce(ci.final_brand_class, qi.brand_class)) AS type_bucket,
    qvi.vendor_id,
    coalesce(pi.final_purchase_price, qvi.cost) AS chosen_cost,
    coalesce(pi.vendor_shipping_cost, qvi.item_shipping, 0) AS chosen_shipping,
    qvi.sla_hours AS chosen_sla,
    po.created_at AS po_at
  from qvm_new_apps.purchase_items pi
  join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
  join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
  join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
  left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id
  where po.created_at >= v_from and po.created_at <= v_to
    and coalesce(pi.final_purchase_price, qvi.cost) is not null;

  create temporary table _offers on commit drop as
  select pp.purchase_item_id,
         min(o.cost) filter (where o.cost > 0) AS lowest,
         max(o.cost) filter (where o.cost > 0) AS highest,
         min(o.sla_hours) filter (where o.cost > 0 and o.cost < pp.chosen_cost) AS cheaper_min_sla
  from _pp pp
  join qvm_new_apps.quotation_vendor_items o on o.quotation_item_id = pp.quotation_item_id
   and (qvm_new_apps.brand_type_bucket(o.available_brand_class) = pp.type_bucket
        or qvm_new_apps.brand_type_bucket(o.available_brand_class) = 'any'
        or pp.type_bucket = 'any')
  group by pp.purchase_item_id, pp.chosen_cost;

  select jsonb_build_object(
    'count', count(*),
    'avg_pct_vs_lowest', coalesce(round(avg( case when of.lowest>0 then 100.0*(pp.chosen_cost-of.lowest)/of.lowest end ),1),0),
    'samples', coalesce(jsonb_agg(jsonb_build_object(
        'part_number', pp.part_number, 'chosen', round(pp.chosen_cost::numeric,2),
        'lowest', round(of.lowest::numeric,2), 'highest', round(of.highest::numeric,2),
        'pct_vs_lowest', case when of.lowest>0 then round(100.0*(pp.chosen_cost-of.lowest)/of.lowest,1) else null end)
        order by (pp.chosen_cost-of.lowest) desc) filter (where of.highest is not null), '[]'::jsonb)
  ) into v_r1
  from _pp pp join _offers of on of.purchase_item_id = pp.purchase_item_id;

  with hist as (
    select pp.purchase_item_id, pp.chosen_cost, pp.part_number,
      (select min(cl.cost)
         from qvm_new_apps.cost_logs cl
         join qvm_new_apps.quotation_vendor_items qv on qv.cost_id = cl.cost_id
         join qvm_new_apps.quotation_items qh on qh.quotation_item_id = qv.quotation_item_id
        where qh.part_number = pp.part_number
          and qvm_new_apps.brand_type_bucket(qh.brand_class) = pp.type_bucket
          and cl.cost > 0
          and cl.created_at >= pp.po_at - interval '12 months'
          and cl.created_at <  pp.po_at) AS hist_min
    from _pp pp
  )
  select jsonb_build_object(
    'count', count(*) filter (where hist_min is not null),
    'avg_pct_vs_hist_min', coalesce(round(avg( case when hist_min>0 then 100.0*(chosen_cost-hist_min)/hist_min end ),1),0),
    'samples', coalesce(jsonb_agg(jsonb_build_object(
        'part_number', part_number, 'chosen', round(chosen_cost::numeric,2),
        'hist_min', round(hist_min::numeric,2),
        'pct', case when hist_min>0 then round(100.0*(chosen_cost-hist_min)/hist_min,1) else null end)
        ) filter (where hist_min is not null), '[]'::jsonb)
  ) into v_r2 from hist;

  with lastv as (
    select pp.purchase_item_id, pp.chosen_cost, pp.part_number, pp.vendor_id,
      (select cl.cost
         from qvm_new_apps.cost_logs cl
         join qvm_new_apps.quotation_vendor_items qv on qv.cost_id = cl.cost_id
         join qvm_new_apps.quotation_items qh on qh.quotation_item_id = qv.quotation_item_id
        where qv.vendor_id = pp.vendor_id
          and qh.part_number = pp.part_number
          and qvm_new_apps.brand_type_bucket(qh.brand_class) = pp.type_bucket
          and cl.cost > 0 and cl.created_at < pp.po_at
        order by cl.created_at desc limit 1) AS last_cost
    from _pp pp where pp.vendor_id is not null
  )
  select jsonb_build_object(
    'count', count(*) filter (where last_cost is not null),
    'avg_pct_vs_last', coalesce(round(avg( case when last_cost>0 then 100.0*(chosen_cost-last_cost)/last_cost end ),1),0),
    'samples', coalesce(jsonb_agg(jsonb_build_object(
        'part_number', part_number, 'chosen', round(chosen_cost::numeric,2),
        'last_cost', round(last_cost::numeric,2),
        'pct', case when last_cost>0 then round(100.0*(chosen_cost-last_cost)/last_cost,1) else null end)
        ) filter (where last_cost is not null), '[]'::jsonb)
  ) into v_r3 from lastv;

  v_financial := jsonb_build_object('vs_rfq', v_r1, 'vs_hist_min', v_r2, 'vs_last_vendor', v_r3);

  create temporary table _dev on commit drop as
  select pp.purchase_item_id, pp.quotation_item_id, pp.quotation_id, pp.chosen_cost, pp.chosen_shipping,
    pp.chosen_sla, pp.po_at, of.lowest, of.cheaper_min_sla,
    greatest(pp.chosen_cost - of.lowest, 0) AS dev_amount,
    case
      when pp.chosen_cost <= of.lowest then 'none'
      when of.cheaper_min_sla is not null and pp.chosen_sla is not null and pp.chosen_sla < of.cheaper_min_sla then 'sla'
      when exists (select 1 from qvm_new_apps.quotation_vendors qvn
                    where qvn.quotation_id = pp.quotation_id
                      and not exists (select 1 from qvm_new_apps.quotation_vendor_items qz
                                       where qz.quotation_item_id = pp.quotation_item_id
                                         and qz.vendor_id = qvn.vendor_id)) then 'never_replied'
      when exists (select 1 from qvm_new_apps.quotation_vendor_items ql
                    where ql.quotation_item_id = pp.quotation_item_id
                      and ql.cost > 0 and ql.cost < pp.chosen_cost
                      and ql.created_at > pp.po_at) then 'late_reply'
      when (of.lowest + coalesce((select min(coalesce(qs.item_shipping,0))
                                   from qvm_new_apps.quotation_vendor_items qs
                                   where qs.quotation_item_id = pp.quotation_item_id and qs.cost = of.lowest),0))
           >= pp.chosen_cost + pp.chosen_shipping then 'shipping'
      else 'unjustified'
    end AS reason
  from _pp pp join _offers of on of.purchase_item_id = pp.purchase_item_id
  where of.lowest is not null;

  select
    coalesce(round(100.0 * sum(dev_amount) / nullif(sum(lowest),0), 1), 0),
    coalesce(round(100.0 * sum(dev_amount) filter (where reason='unjustified') / nullif(sum(lowest),0), 1), 0)
  into v_raw_pct, v_adj_pct
  from _dev;

  v_quality := jsonb_build_object(
    'raw_deviation_pct', v_raw_pct,
    'adjusted_deviation_pct', v_adj_pct,
    'breakdown', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'count', c) order by c desc)
                           from (select reason, count(*) AS c from _dev where reason<>'none' group by reason) b), '[]'::jsonb),
    'total_deviated', (select count(*) from _dev where reason<>'none')
  );

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'volume', jsonb_build_object('total_items_priced', v_total_items, 'total_pos_issued', v_total_pos, 'by_employee', v_volume),
    'time', v_time,
    'financial', v_financial,
    'quality', v_quality
  ));
end; $$;

notify pgrst, 'reload schema';
