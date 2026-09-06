-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.get_vendors_report(
  p_from timestamptz default null, p_to timestamptz default null, p_vendor int default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_from timestamptz := coalesce(p_from, '2000-01-01'::timestamptz);
  v_to   timestamptz := coalesce(p_to,   now());
  v_total_value numeric; v_rows jsonb; v_by_city jsonb;
  v_t_requests int; v_t_invites int; v_t_wins int;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  create temporary table _v on commit drop as
  with inv as (select qv.vendor_id, count(*)::int AS invites,
      count(*) filter (where exists (select 1 from qvm_new_apps.quotation_vendor_items qi where qi.quotation_vendor_id = qv.quotation_vendor_id))::int AS responded
    from qvm_new_apps.quotation_vendors qv where qv.created_at >= v_from and qv.created_at <= v_to group by qv.vendor_id),
  resp as (select qv.vendor_id, round(avg(qvm_new_apps.business_minutes(qv.created_at, r.first_resp)),1) AS avg_min
    from qvm_new_apps.quotation_vendors qv join lateral (select min(qi.created_at) AS first_resp from qvm_new_apps.quotation_vendor_items qi where qi.quotation_vendor_id = qv.quotation_vendor_id) r on true
    where r.first_resp is not null and r.first_resp > qv.created_at and qv.created_at >= v_from and qv.created_at <= v_to group by qv.vendor_id),
  wins as (select qvi.vendor_id, count(*)::int AS wins from qvm_new_apps.quotation_vendor_items qvi where qvi.best_cost is true and qvi.created_at >= v_from and qvi.created_at <= v_to group by qvi.vendor_id),
  req as (select po.vendor_id, count(*)::int AS requests from qvm_new_apps.purchase_orders po where po.created_at >= v_from and po.created_at <= v_to group by po.vendor_id),
  val as (select po.vendor_id, sum(coalesce(pi.final_purchase_price, qvi.cost) * coalesce(pi.approved_qty,1))::numeric AS purchase_value
    from qvm_new_apps.purchase_items pi join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id where po.created_at >= v_from and po.created_at <= v_to group by po.vendor_id),
  comp as (select qvi.vendor_id, round(avg(100.0*(qvi.cost - pa.avg_cost)/nullif(pa.avg_cost,0))::numeric,1) AS comp_pct
    from qvm_new_apps.quotation_vendor_items qvi join (select quotation_item_id, qvm_new_apps.brand_type_bucket(available_brand_class) AS bucket, avg(cost) AS avg_cost from qvm_new_apps.quotation_vendor_items where cost > 0 group by quotation_item_id, qvm_new_apps.brand_type_bucket(available_brand_class)) pa
      on pa.quotation_item_id = qvi.quotation_item_id and pa.bucket = qvm_new_apps.brand_type_bucket(qvi.available_brand_class)
    where qvi.cost > 0 and qvi.created_at >= v_from and qvi.created_at <= v_to group by qvi.vendor_id),
  ret as (select ri.main_vendor AS vendor_id, count(*)::int AS returns from qvm_new_apps.return_issues ri where ri.main_vendor is not null and ri.created_at >= v_from and ri.created_at <= v_to group by ri.main_vendor),
  rec as (select f.vendor_id, count(*)::int AS faults,
      count(*) filter (where exists (select 1 from qvm_new_apps.purchase_items pi join qvm_new_apps.vendor_creditnote_items vc on vc.purchase_item_id = pi.purchase_item_id where pi.confirmed_item_id = f.confirmed_item_id))::int AS recovered
    from (select ri.main_vendor AS vendor_id, ri.confirmed_item_id from qvm_new_apps.return_issues ri where ri.main_vendor is not null and ri.return_reasons in (142,143,144,145,146) and ri.created_at >= v_from and ri.created_at <= v_to) f group by f.vendor_id),
  ontime as (select po.vendor_id, count(*)::int AS delivered,
      count(*) filter (where d.delivery_date <= po.created_at + make_interval(hours => coalesce(qvi.sla_hours,72)::int))::int AS on_time
    from qvm_new_apps.deliveries d join qvm_new_apps.purchase_orders po on po.confirmed_order_id = d.confirmed_order_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = (select pi.cost_id from qvm_new_apps.purchase_items pi where pi.purchase_order_id = po.purchase_order_id limit 1)
    where d.delivery_date is not null and d.created_at >= v_from and d.created_at <= v_to group by po.vendor_id),
  universe as (select vendor_id from inv union select vendor_id from wins union select vendor_id from req union select vendor_id from ret union select vendor_id from val)
  select u.vendor_id, v.vendor_name, vb.city, coalesce(rq.requests,0) AS requests, coalesce(i.invites,0) AS invites, coalesce(i.responded,0) AS responded, coalesce(w.wins,0) AS wins,
    coalesce(rs.avg_min,0) AS avg_response_min, coalesce(vl.purchase_value,0) AS purchase_value, c.comp_pct, coalesce(rt.returns,0) AS returns,
    coalesce(rc.faults,0) AS faults, coalesce(rc.recovered,0) AS recovered, coalesce(ot.delivered,0) AS delivered, coalesce(ot.on_time,0) AS on_time
  from universe u left join qvm_new_apps.vendors v on v.vendor_id = u.vendor_id left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = v.preferred_branch_id
  left join inv i on i.vendor_id = u.vendor_id left join resp rs on rs.vendor_id = u.vendor_id left join wins w on w.vendor_id = u.vendor_id
  left join req rq on rq.vendor_id = u.vendor_id left join val vl on vl.vendor_id = u.vendor_id left join comp c on c.vendor_id = u.vendor_id
  left join ret rt on rt.vendor_id = u.vendor_id left join rec rc on rc.vendor_id = u.vendor_id left join ontime ot on ot.vendor_id = u.vendor_id
  where (p_vendor is null or u.vendor_id = p_vendor);
  select sum(purchase_value), sum(requests), sum(invites), sum(wins) into v_total_value, v_t_requests, v_t_invites, v_t_wins from _v;
  select coalesce(jsonb_agg(jsonb_build_object('vendor_id', vendor_id, 'vendor_name', vendor_name, 'city', city, 'requests', requests, 'invites', invites, 'wins', wins,
    'win_rate_pct', case when invites>0 then round(100.0*wins/invites,1) else 0 end, 'response_rate_pct', case when invites>0 then round(100.0*responded/invites,1) else 0 end,
    'avg_response_min', avg_response_min, 'purchase_value', round(purchase_value,2), 'pct_of_total', case when v_total_value>0 then round(100.0*purchase_value/v_total_value,1) else 0 end,
    'price_competitiveness_pct', comp_pct, 'return_pct', case when requests>0 then round(100.0*returns/requests,1) else 0 end,
    'cost_recovery_pct', case when faults>0 then round(100.0*recovered/faults,1) else null end, 'on_time_pct', case when delivered>0 then round(100.0*on_time/delivered,1) else null end)
    order by requests desc, wins desc, invites desc), '[]'::jsonb) into v_rows from _v;
  select coalesce(jsonb_agg(jsonb_build_object('city', coalesce(city,'—'), 'vendors', n, 'requests', requests, 'invites', invites, 'wins', wins,
      'purchase_value', round(value,2), 'pct_of_total', case when v_total_value>0 then round(100.0*value/v_total_value,1) else 0 end) order by value desc nulls last, requests desc), '[]'::jsonb)
  into v_by_city from (select city, count(*)::int AS n, sum(requests)::int AS requests, sum(invites)::int AS invites, sum(wins)::int AS wins, sum(purchase_value)::numeric AS value from _v group by city) c;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to), 'sla_available', true,
    'summary', jsonb_build_object('vendors', (select count(*) from _v), 'total_requests', coalesce(v_t_requests,0), 'total_invites', coalesce(v_t_invites,0), 'total_wins', coalesce(v_t_wins,0), 'total_purchase_value', round(coalesce(v_total_value,0),2)),
    'by_vendor', v_rows, 'by_city', v_by_city));
end; $$;
grant execute on function qvm_new_apps.get_vendors_report(timestamptz,timestamptz,int) to authenticated;
notify pgrst, 'reload schema';
