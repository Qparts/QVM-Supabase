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
  v_delay_days numeric; v_conc_pct numeric;
  v_total_reqs int; v_total_items int;
  v_funnel jsonb; v_funnel_emp jsonb; v_stage_pct jsonb; v_stages jsonb;
  v_order_value jsonb; v_margin jsonb; v_lost jsonb; v_po jsonb; v_vc jsonb;
  v_brands jsonb; v_handoffs int; v_alerts jsonb; v_ship numeric;
  v_collection jsonb; v_branch jsonb; v_bonus_ar jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object('user_id', e.am, 'user_name', ud.user_name,
     'requests', e.reqs, 'items', e.items) order by e.reqs desc), '[]'::jsonb)
    into v_funnel_emp
  from (
    select q.account_manager AS am, count(distinct q.quotation_id) AS reqs, count(qi.quotation_item_id) AS items
    from qvm_new_apps.quotations q
    left join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
    where q.created_at >= v_from and q.created_at <= v_to
    group by q.account_manager
  ) e left join qvm_new_apps.user_data ud on ud.user_id = e.am;

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
  select
    jsonb_build_object(
      'pricing_min',    coalesce(round(avg(qvm_new_apps.business_minutes(t_new,  t_priced)) filter (where t_priced>t_new),1),0),
      'processing_min', coalesce(round(avg(qvm_new_apps.business_minutes(t_conf, t_proc))   filter (where t_proc>t_conf),1),0),
      'delivery_min',   coalesce(round(avg(qvm_new_apps.business_minutes(t_proc, t_deliv))  filter (where t_deliv>t_proc),1),0)),
    jsonb_build_object(
      'pricing_pct',    case when count(*) filter (where t_new is not null)>0    then round(100.0*count(*) filter (where t_priced is not null)/count(*) filter (where t_new is not null),1) else 0 end,
      'processing_pct', case when count(*) filter (where t_conf is not null)>0   then round(100.0*count(*) filter (where t_proc is not null)/count(*) filter (where t_conf is not null),1) else 0 end,
      'delivery_pct',   case when count(*) filter (where t_proc is not null)>0   then round(100.0*count(*) filter (where t_deliv is not null)/count(*) filter (where t_proc is not null),1) else 0 end)
    into v_stages, v_stage_pct
  from ts;

  v_stages := v_stages || jsonb_build_object('bottleneck',
    (select key from (values
       ('Pricing', (v_stages->>'pricing_min')::numeric),
       ('Processing', (v_stages->>'processing_min')::numeric),
       ('Delivery', (v_stages->>'delivery_min')::numeric)) x(key,val)
     order by val desc nulls last limit 1));

  with cc as (
    select cost_range_id, cost_range,
      (cost_range->>0)::numeric AS lo, (cost_range->>1)::numeric AS hi,
      ((cost_range->>0)||'-'||(cost_range->>1)) AS lbl
    from qvm_new_apps.cost_categories
  ),
  base as (
    select qi.quotation_item_id, qi.price_before_vat, qvi.cost, qi.brand_class, qi.part_category,
      (select cost_range_id from cc where qvi.cost >= cc.lo and (qvi.cost < cc.hi or cc.hi is null) order by cc.lo desc limit 1) AS crid
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
    where q.created_at >= v_from and q.created_at <= v_to and qi.price_before_vat > 0 and qvi.cost > 0
  ),
  withtarget as (
    select b.*, cc.lbl,
      (select pm.percentage from qvm_new_apps.profit_margins pm
        join qvm_new_apps.profit_categories pc on pc.category_id = pm.profit_categories_id
        where pm.cost_range_id = b.crid and pc.brand_class = b.brand_class
          and (pc.part_category = b.part_category or pc.part_category is null)
        order by (pc.part_category = b.part_category) desc nulls last limit 1) AS target_frac
    from base b join cc on cc.cost_range_id = b.crid
  )
  select coalesce(jsonb_agg(jsonb_build_object('range', g.lbl, 'cost_range_id', g.crid,
      'actual_pct', g.actual_pct, 'target_pct', g.target_pct, 'items', g.n) order by g.crid), '[]'::jsonb)
    into v_margin
  from (
    select crid, lbl,
      round(avg(100.0*(price_before_vat - cost)/nullif(price_before_vat,0))::numeric,1) AS actual_pct,
      round((avg(target_frac)*100)::numeric,1) AS target_pct,
      count(*) AS n
    from withtarget group by crid, lbl
  ) g;

  select jsonb_build_object(
    'raw_count', count(*), 'raw_value', coalesce(sum(qi.total_price_before_vat),0)::numeric,
    'adjusted_count', count(*) filter (where qi.cancellation_reason is distinct from 202 and qi.cancellation_reason is distinct from 203 and qi.cancellation_reason is distinct from 204),
    'adjusted_value', coalesce(sum(qi.total_price_before_vat) filter (where qi.cancellation_reason is distinct from 202 and qi.cancellation_reason is distinct from 203 and qi.cancellation_reason is distinct from 204),0)::numeric,
    'by_reason', coalesce((select jsonb_agg(jsonb_build_object('reason', ld.list_data, 'count', z.c) order by z.c desc)
                  from (select qi2.cancellation_reason AS r, count(*) AS c
                        from qvm_new_apps.quotation_items qi2 join qvm_new_apps.quotations q2 on q2.quotation_id=qi2.quotation_id
                        where qi2.item_status in (18,20,268) and q2.created_at>=v_from and q2.created_at<=v_to
                        group by qi2.cancellation_reason) z
                  left join qvm_new_apps.list_data ld on ld.list_data_id=z.r), '[]'::jsonb))
    into v_lost
  from qvm_new_apps.quotation_items qi join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.item_status in (18,20,268) and q.created_at >= v_from and q.created_at <= v_to;

  select jsonb_build_object('total', count(*),
    'matched', count(*) filter (where coalesce(vendor_invoice_number,'')<>'' or coalesce(vendor_invoice_url,'')<>''),
    'pct', case when count(*)>0 then round(100.0*count(*) filter (where coalesce(vendor_invoice_number,'')<>'' or coalesce(vendor_invoice_url,'')<>'')/count(*),1) else 0 end)
    into v_po from qvm_new_apps.purchase_orders where created_at >= v_from and created_at <= v_to;

  with pv as (
    select po.vendor_id, sum(coalesce(pi.final_purchase_price, qvi.cost)*coalesce(pi.approved_qty,1))::numeric AS val
    from qvm_new_apps.purchase_items pi
    join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id
    where po.created_at >= v_from and po.created_at <= v_to group by po.vendor_id
  ), tot as (select nullif(sum(val),0) AS t from pv)
  select jsonb_build_object('threshold_pct', v_conc_pct,
    'top', coalesce(jsonb_agg(jsonb_build_object('vendor', v.vendor_name, 'value', round(pv.val,2),
             'pct', round(100.0*pv.val/(select t from tot),1)) order by pv.val desc), '[]'::jsonb),
    'flagged', coalesce(max(100.0*pv.val/(select t from tot)) > v_conc_pct, false))
    into v_vc from pv left join qvm_new_apps.vendors v on v.vendor_id = pv.vendor_id;

  select coalesce(jsonb_agg(jsonb_build_object('brand', ld.list_data, 'rfq', b.rfq, 'confirmed', b.confirmed, 'returned', b.returned) order by b.rfq desc), '[]'::jsonb)
    into v_brands
  from (
    select qi.main_brand,
      count(*) AS rfq,
      count(*) filter (where exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)) AS confirmed,
      count(*) filter (where exists (select 1 from qvm_new_apps.confirmed_items ci
                                      join qvm_new_apps.return_issues ri on ri.confirmed_item_id=ci.confirmed_item_id
                                      where ci.quotation_item_id=qi.quotation_item_id)) AS returned
    from qvm_new_apps.quotation_items qi join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    where q.created_at >= v_from and q.created_at <= v_to group by qi.main_brand
  ) b left join qvm_new_apps.list_data ld on ld.list_data_id = b.main_brand;

  select coalesce(sum(greatest(cnt-1,0)),0) into v_handoffs
  from (select quotation_id, count(*) AS cnt from qvm_new_apps.quotation_account_managers group by quotation_id) z;

  with last_change as (
    select coalesce(s.quotation_item_id, ci.quotation_item_id) AS qiid, max(s.created_at) AS last_at
    from qvm_new_apps.status_logs s
    left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = s.confirmed_item_id
    group by coalesce(s.quotation_item_id, ci.quotation_item_id)
  )
  select jsonb_build_object('threshold_days', v_delay_days, 'stalled_count', count(*))
    into v_alerts
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  left join last_change lc on lc.qiid = qi.quotation_item_id
  where qi.item_status not in (18,20,23,31,268)
    and coalesce(lc.last_at, qi.created_at) < now() - make_interval(days => coalesce(v_delay_days,3)::int)
    and q.created_at >= v_from and q.created_at <= v_to;

  select coalesce(sum(shipping_price),0)::numeric into v_ship
  from qvm_new_apps.quotations where created_at >= v_from and created_at <= v_to;

  select jsonb_build_object(
    'avg_days', round(avg(extract(epoch from (inv.created_at - d.delivery_date))/86400.0)::numeric,1),
    'sample_count', count(*))
    into v_collection
  from qvm_new_apps.deliveries d
  join qvm_new_apps.invoices inv on inv.confirmed_order_id = d.confirmed_order_id
  where d.delivery_date is not null and inv.created_at is not null
    and inv.created_at >= v_from and inv.created_at <= v_to;

  select coalesce(jsonb_agg(jsonb_build_object('branch', cb.branch_name, 'target', bt.target,
      'actual', round(coalesce(s.actual,0),2),
      'pct', case when bt.target>0 then round((100.0*coalesce(s.actual,0)/bt.target)::numeric,1) else null end) order by bt.target desc), '[]'::jsonb)
    into v_branch
  from qvm_new_apps.branch_targets bt
  left join qvm_new_apps.client_branches cb on cb.customer_id = bt.branch_id
  left join lateral (
    select sum(qi.total_price_before_vat)::numeric AS actual
    from qvm_new_apps.quotation_items qi join qvm_new_apps.quotations q on q.quotation_id=qi.quotation_id
    where qi.customer_id = bt.branch_id and exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)
      and q.created_at >= v_from and q.created_at <= v_to
  ) s on true;

  select jsonb_build_object(
    'bonus_eligible_branches', (
      select count(*) from qvm_new_apps.branch_targets bt
      where bt.target > 0 and coalesce((select sum(qi.total_price_before_vat)
        from qvm_new_apps.quotation_items qi join qvm_new_apps.quotations q on q.quotation_id=qi.quotation_id
        where qi.customer_id=bt.branch_id and exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id=qi.quotation_item_id)
          and q.created_at>=v_from and q.created_at<=v_to),0) >= bt.target),
    'ar_over_30_count', (select count(*) from qvm_new_apps.invoices i
       where i.paid_at is null and coalesce(i.due_date, i.created_at::date) < (now() - interval '30 days')::date),
    'ar_over_30_value', 0)
    into v_bonus_ar;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'totals', jsonb_build_object('requests', v_total_reqs, 'items', v_total_items),
    'funnel', v_funnel, 'funnel_by_employee', v_funnel_emp,
    'stage_pct', v_stage_pct, 'stages', v_stages,
    'order_value', v_order_value, 'margin', v_margin, 'lost', v_lost,
    'po_invoice', v_po, 'vendor_concentration', v_vc, 'brands', v_brands,
    'assignment', jsonb_build_object('handoffs', v_handoffs), 'alerts', v_alerts,
    'shipping_revenue', round(v_ship,2),
    'collection', v_collection, 'branch_targets', v_branch, 'bonus_ar', v_bonus_ar
  ));
end; $$;

grant execute on function qvm_new_apps.get_overview_report(timestamptz,timestamptz) to authenticated;
notify pgrst, 'reload schema';
