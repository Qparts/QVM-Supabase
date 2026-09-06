-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.get_overview_report(
  p_from timestamptz default null, p_to timestamptz default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_from timestamptz := coalesce(p_from, '2000-01-01'::timestamptz);
  v_to   timestamptz := coalesce(p_to,   now());
  v_funnel jsonb; v_order_value jsonb; v_stages jsonb; v_margin jsonb;
  v_lost jsonb; v_po jsonb; v_vc jsonb; v_brands jsonb;
  v_handoffs int; v_alerts jsonb; v_ship numeric;
  v_delay_days numeric; v_conc_pct numeric;
  v_total_reqs int; v_total_items int;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;

  select value into v_delay_days from qvm_new_apps.report_settings_thresholds where key='order_delay_threshold_days';
  select value into v_conc_pct  from qvm_new_apps.report_settings_thresholds where key='vendor_concentration_threshold_pct';

  select count(distinct q.quotation_id), count(qi.quotation_item_id)
    into v_total_reqs, v_total_items
  from qvm_new_apps.quotations q
  left join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
  where q.created_at >= v_from and q.created_at <= v_to;

  select coalesce(jsonb_agg(jsonb_build_object('status_id', st, 'status', ld.list_data, 'count', c) order by c desc), '[]'::jsonb)
    into v_funnel
  from (select qi.item_status AS st, count(*) AS c
        from qvm_new_apps.quotation_items qi
        join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
        where q.created_at >= v_from and q.created_at <= v_to
        group by qi.item_status) f
  left join qvm_new_apps.list_data ld on ld.list_data_id = f.st;

  select jsonb_build_object(
     'confirmed', coalesce(sum(qi.total_price_before_vat) filter (where exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)),0)::numeric,
     'canceled',  coalesce(sum(qi.total_price_before_vat) filter (where qi.item_status in (18,20,268)),0)::numeric,
     'pending',   coalesce(sum(qi.total_price_before_vat) filter (where qi.item_status not in (18,20,268) and not exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)),0)::numeric)
    into v_order_value
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where q.created_at >= v_from and q.created_at <= v_to;

  with sl as (
    select coalesce(s.quotation_item_id, ci.quotation_item_id) AS qiid, s.item_status, s.created_at
    from qvm_new_apps.status_logs s
    left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = s.confirmed_item_id
    where s.created_at >= v_from and s.created_at <= v_to
  ),
  ts as (
    select qiid,
      min(created_at) filter (where item_status=15) AS t_new,
      min(created_at) filter (where item_status=17) AS t_priced,
      min(created_at) filter (where item_status=19) AS t_conf,
      min(created_at) filter (where item_status=21) AS t_proc,
      min(created_at) filter (where item_status=23) AS t_deliv
    from sl group by qiid
  )
  select jsonb_build_object(
    'pricing_min',    coalesce(round(avg(qvm_new_apps.business_minutes(t_new,  t_priced)) filter (where t_priced>t_new),1),0),
    'processing_min', coalesce(round(avg(qvm_new_apps.business_minutes(t_conf, t_proc))   filter (where t_proc>t_conf),1),0),
    'delivery_min',   coalesce(round(avg(qvm_new_apps.business_minutes(t_proc, t_deliv))  filter (where t_deliv>t_proc),1),0)
  ) into v_stages from ts;

  v_stages := v_stages || jsonb_build_object('bottleneck',
    (select key from (values
       ('Pricing', (v_stages->>'pricing_min')::numeric),
       ('Processing', (v_stages->>'processing_min')::numeric),
       ('Delivery', (v_stages->>'delivery_min')::numeric)) x(key,val)
     order by val desc nulls last limit 1));

  select coalesce(jsonb_agg(jsonb_build_object('range', b.lbl, 'avg_margin_pct', b.mpct, 'items', b.n) order by b.ord), '[]'::jsonb)
    into v_margin
  from (
    select ord, lbl,
      round(avg(100.0*(qi.price_before_vat - qvi.cost)/nullif(qi.price_before_vat,0))::numeric,1) AS mpct,
      count(*) AS n
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
    cross join lateral (
      select case
        when qvi.cost < 100 then 1 when qvi.cost < 500 then 2
        when qvi.cost < 1000 then 3 when qvi.cost < 5000 then 4 else 5 end AS ord,
        case
        when qvi.cost < 100 then '< 100' when qvi.cost < 500 then '100-500'
        when qvi.cost < 1000 then '500-1000' when qvi.cost < 5000 then '1000-5000' else '5000+' end AS lbl
    ) bkt
    where q.created_at >= v_from and q.created_at <= v_to
      and qi.price_before_vat > 0 and qvi.cost > 0
    group by ord, lbl
  ) b;

  select jsonb_build_object(
    'count', count(*),
    'value', coalesce(sum(qi.total_price_before_vat),0)::numeric,
    'by_reason', coalesce((select jsonb_agg(jsonb_build_object('reason', ld.list_data, 'count', z.c) order by z.c desc)
                  from (select qi2.cancellation_reason AS r, count(*) AS c
                        from qvm_new_apps.quotation_items qi2
                        join qvm_new_apps.quotations q2 on q2.quotation_id=qi2.quotation_id
                        where qi2.item_status in (18,20,268) and q2.created_at>=v_from and q2.created_at<=v_to
                        group by qi2.cancellation_reason) z
                  left join qvm_new_apps.list_data ld on ld.list_data_id=z.r), '[]'::jsonb))
    into v_lost
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.item_status in (18,20,268) and q.created_at >= v_from and q.created_at <= v_to;

  select jsonb_build_object('total', count(*),
    'matched', count(*) filter (where coalesce(vendor_invoice_number,'')<>'' or coalesce(vendor_invoice_url,'')<>''),
    'pct', case when count(*)>0 then round(100.0*count(*) filter (where coalesce(vendor_invoice_number,'')<>'' or coalesce(vendor_invoice_url,'')<>'')/count(*),1) else 0 end)
    into v_po
  from qvm_new_apps.purchase_orders where created_at >= v_from and created_at <= v_to;

  with pv as (
    select po.vendor_id, sum(coalesce(pi.final_purchase_price, qvi.cost)*coalesce(pi.approved_qty,1))::numeric AS val
    from qvm_new_apps.purchase_items pi
    join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id
    where po.created_at >= v_from and po.created_at <= v_to
    group by po.vendor_id
  ), tot as (select nullif(sum(val),0) AS t from pv)
  select jsonb_build_object('threshold_pct', v_conc_pct,
    'top', coalesce(jsonb_agg(jsonb_build_object('vendor', v.vendor_name, 'value', round(pv.val,2),
             'pct', round(100.0*pv.val/(select t from tot),1)) order by pv.val desc), '[]'::jsonb),
    'flagged', coalesce(max(100.0*pv.val/(select t from tot)) > v_conc_pct, false))
    into v_vc
  from pv left join qvm_new_apps.vendors v on v.vendor_id = pv.vendor_id;

  select coalesce(jsonb_agg(jsonb_build_object('brand', ld.list_data, 'rfq', b.rfq, 'confirmed', b.confirmed) order by b.rfq desc), '[]'::jsonb)
    into v_brands
  from (
    select qi.main_brand,
      count(*) AS rfq,
      count(*) filter (where exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)) AS confirmed
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    where q.created_at >= v_from and q.created_at <= v_to
    group by qi.main_brand
  ) b left join qvm_new_apps.list_data ld on ld.list_data_id = b.main_brand;

  select coalesce(sum(greatest(cnt-1,0)),0) into v_handoffs
  from (select quotation_id, count(*) AS cnt from qvm_new_apps.quotation_account_managers group by quotation_id) z;

  select jsonb_build_object('threshold_days', v_delay_days, 'stalled_count', count(*))
    into v_alerts
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.item_status not in (18,20,23,31,268)
    and coalesce(qi.updated_at, qi.created_at) < now() - make_interval(days => coalesce(v_delay_days,3)::int)
    and q.created_at >= v_from and q.created_at <= v_to;

  select coalesce(sum(shipping_price),0)::numeric into v_ship
  from qvm_new_apps.quotations where created_at >= v_from and created_at <= v_to;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'totals', jsonb_build_object('requests', v_total_reqs, 'items', v_total_items),
    'funnel', v_funnel, 'order_value', v_order_value, 'stages', v_stages, 'margin', v_margin,
    'lost', v_lost, 'po_invoice', v_po, 'vendor_concentration', v_vc, 'brands', v_brands,
    'assignment', jsonb_build_object('handoffs', v_handoffs), 'alerts', v_alerts,
    'shipping_revenue', round(v_ship,2)
  ));
end; $$;

grant execute on function qvm_new_apps.get_overview_report(timestamptz,timestamptz) to authenticated;
notify pgrst, 'reload schema';
