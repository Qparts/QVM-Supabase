-- The average confirmation time is from the order being raised to its confirmation.
--
-- quotations.created_at → confirmed_orders.created_at, as the workshop reads it; the first
-- send to a vendor is not the measure. The rest of get_workshop_reports is unchanged.

set search_path to qvm_new_apps, public;

create or replace function qvm_new_apps.get_workshop_reports(
  p_branch_id integer default null,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_scope integer[];
  v_to timestamptz := coalesce(p_date_to, now());
  v_from timestamptz := p_date_from;
  v_prev_from timestamptz;
  v_prev_to timestamptz;
  v_result jsonb;
begin
  if not qvm_new_apps.is_internal_user() then
    return jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', null);
  end if;
  v_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());
  if v_from is not null then
    v_prev_to := v_from;
    v_prev_from := v_from - (v_to - v_from);
  end if;

  with
  -- Every order whose lines sit in a branch in scope, with the branch it was raised for.
  scoped as (
    select q.quotation_id, q.created_at, min(qi.customer_id) as branch_id
      from qvm_new_apps.quotations q
      join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
     where (p_branch_id is null or qi.customer_id = p_branch_id)
       and (v_scope is null or qi.customer_id = any(v_scope))
     group by q.quotation_id, q.created_at
  ),
  branch as (
    select cb.customer_id, coalesce(nullif(btrim(vb.name), ''), cb.branch_name) as name,
           coalesce(nullif(btrim(cb.city), ''), '—') as city
      from qvm_new_apps.client_branches cb
      left join qvm_new_apps.v_client_branches vb on vb.customer_id = cb.customer_id
  ),
  -- Where each order stands.
  classified as (
    select s.*,
           co.confirmed_order_id, co.created_at as confirmed_at,
           (exists (select 1 from qvm_new_apps.delivery_notes dn
                      join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = dn.confirmed_item_id
                     where ci.confirmed_order_id = co.confirmed_order_id)
            or exists (select 1 from qvm_new_apps.quotation_items qi
                        where qi.quotation_id = s.quotation_id
                          and qi.item_status in (23, 25, 26, 27, 28, 29, 30, 31, 213, 214, 215))) as has_delivery,
           not exists (select 1 from qvm_new_apps.quotation_items qi
                        where qi.quotation_id = s.quotation_id
                          and qi.item_status not in (18, 268, 20)) as all_cancelled,
           (co.confirmed_order_id is not null and not exists (
              select 1 from qvm_new_apps.quotation_items qi
               where qi.quotation_id = s.quotation_id
                 and qi.item_status not in (18, 268, 20, 23, 25, 26, 27, 28, 29, 30, 31, 213, 214, 215))) as completed
      from scoped s
      left join lateral (select co.confirmed_order_id, co.created_at
                           from qvm_new_apps.confirmed_orders co
                          where co.quotation_id = s.quotation_id
                          order by co.created_at limit 1) co on true
  ),
  in_window as (
    select * from classified
     where (v_from is null or created_at >= v_from) and created_at <= v_to
  ),
  in_prev as (
    select * from classified
     where v_prev_from is not null and created_at >= v_prev_from and created_at < v_prev_to
  ),
  kpi as (
    select count(*) as sent,
           count(*) filter (where confirmed_order_id is null and not all_cancelled) as pending,
           count(*) filter (where has_delivery) as delivered,
           count(*) filter (where completed) as completed
      from in_window
  ),
  kpi_prev as (
    select count(*) as sent,
           count(*) filter (where confirmed_order_id is null and not all_cancelled) as pending,
           count(*) filter (where has_delivery) as delivered,
           count(*) filter (where completed) as completed
      from in_prev
  ),
  per_branch as (
    select w.branch_id, b.name,
           count(*) as sent,
           count(*) filter (where w.confirmed_order_id is null and not w.all_cancelled) as pending,
           count(*) filter (where w.has_delivery) as delivered,
           count(*) filter (where w.completed) as completed
      from in_window w
      left join branch b on b.customer_id = w.branch_id
     group by w.branch_id, b.name
  ),
  -- Raised → confirmed: quotations.created_at to confirmed_orders.created_at.
  confirmation as (
    select w.quotation_id, w.created_at, w.confirmed_at as started_at
      from in_window w
     where w.confirmed_at is not null and w.confirmed_at > w.created_at
  ),
  confirmation_weeks as (
    select date_trunc('week', started_at) as week_start,
           avg(extract(epoch from (started_at - created_at)) / 3600.0) as avg_hours, count(*) as n
      from confirmation group by 1
  ),
  -- First priced line (the pricing log, as the lifecycle report reads it) → the workshop's confirmation.
  speed as (
    select w.quotation_id, min(pl.created_at) as priced_at, w.confirmed_at
      from in_window w
      join qvm_new_apps.quotation_items qi on qi.quotation_id = w.quotation_id
      join qvm_new_apps.pricing_logs pl on pl.quotation_item_id = qi.quotation_item_id
     where w.confirmed_at is not null
     group by w.quotation_id, w.confirmed_at
    having w.confirmed_at > min(pl.created_at)
  ),
  -- Purchase orders of the orders in the window, with the branch and the vendor's city.
  pos as (
    select po.purchase_order_id, po.created_at, w.branch_id, b.city as to_city,
           coalesce(nullif(btrim(vb.city), ''), vc.name, '—') as from_city
      from in_window w
      join qvm_new_apps.purchase_orders po on po.confirmed_order_id = w.confirmed_order_id
      left join branch b on b.customer_id = w.branch_id
      left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = po.vendor_branch_id
      left join qvm_new_apps.vendors v on v.vendor_id = po.vendor_id
      left join qvm_new_apps.v_cities vc on vc.city_id = v.city_id
  ),
  routes as (
    select p.from_city, p.to_city, count(*) as n,
           avg(extract(epoch from (d.delivered_at - p.created_at)) / 86400.0) as avg_days
      from pos p
      join lateral (select min(dn.created_at) as delivered_at
                      from qvm_new_apps.purchase_items pi
                      join qvm_new_apps.delivery_notes dn on dn.confirmed_item_id = pi.confirmed_item_id
                     where pi.purchase_order_id = p.purchase_order_id) d on d.delivered_at > p.created_at
     group by p.from_city, p.to_city
  ),
  -- Lines cancelled before anything was bought.
  cancelled as (
    select qi.quotation_item_id, qi.quantity, coalesce(qi.price_before_vat, 0) * coalesce(qi.quantity, 1) as value,
           coalesce(rl.list_data, rl2.list_data, 'Other') as reason
      from in_window w
      join qvm_new_apps.quotation_items qi on qi.quotation_id = w.quotation_id
      left join qvm_new_apps.list_data rl on rl.list_data_id = qi.cancellation_reason
      left join lateral (select c.reason_id from qvm_new_apps.quotation_item_cancellations c
                          where c.quotation_item_id = qi.quotation_item_id order by c.created_at limit 1) c on true
      left join qvm_new_apps.list_data rl2 on rl2.list_data_id = c.reason_id
     where qi.item_status in (18, 268)
       and not exists (select 1 from qvm_new_apps.confirmed_items ci
                         join qvm_new_apps.purchase_items pi on pi.confirmed_item_id = ci.confirmed_item_id
                        where ci.quotation_item_id = qi.quotation_item_id)
  ),
  -- Lines returned after purchase, per branch.
  returned as (
    select w.branch_id, b.name, count(*) as n,
           sum(coalesce(ri.return_qty, 0) * coalesce(qi.price_before_vat, 0)) as value
      from in_window w
      join qvm_new_apps.confirmed_items ci on ci.confirmed_order_id = w.confirmed_order_id
      join qvm_new_apps.return_items ri on ri.confirmed_item_id = ci.confirmed_item_id
      join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
      left join branch b on b.customer_id = w.branch_id
     group by w.branch_id, b.name
  ),
  -- Signals.
  cancels as (
    select c.cancellation_id, (c.confirmed_item_id is not null or c.purchase_item_id is not null) as late
      from in_window w
      join qvm_new_apps.quotation_items qi on qi.quotation_id = w.quotation_id
      join qvm_new_apps.quotation_item_cancellations c on c.quotation_item_id = qi.quotation_item_id
  ),
  additions as (
    select count(*) as items_total,
           count(*) filter (where qi.created_at > w.confirmed_at + interval '5 minutes') as late
      from in_window w
      join qvm_new_apps.quotation_items qi on qi.quotation_id = w.quotation_id
     where w.confirmed_at is not null
  ),
  internal_notes as (
    select count(*) as n
      from qvm_new_apps.notes nt
     where nt.is_internal and coalesce(nt.is_deleted, false) = false
       and ((nt.note_type = 'quotations' and nt.type_id in (select quotation_id from in_window))
         or (nt.note_type = 'quotation_items' and nt.type_id in (
               select qi.quotation_item_id from qvm_new_apps.quotation_items qi
                where qi.quotation_id in (select quotation_id from in_window))))
  ),
  -- The last seven days of the window, by weekday (Saturday first) and shift (before / after 15:00 Riyadh).
  shifts as (
    select ((extract(dow from (s.created_at at time zone 'Asia/Riyadh'))::int + 1) % 7) as dow,
           count(*) filter (where extract(hour from (s.created_at at time zone 'Asia/Riyadh')) < 15) as first_shift,
           count(*) filter (where extract(hour from (s.created_at at time zone 'Asia/Riyadh')) >= 15) as second_shift
      from classified s
     where s.created_at > v_to - interval '7 days' and s.created_at <= v_to
     group by 1
  ),
  -- Purchase cost over the last six weeks of the window.
  spend_lines as (
    select po.purchase_order_id, po.created_at, b.city,
           coalesce(pi.final_purchase_price, qvi.cost, 0) * coalesce(pi.approved_qty, 1) as amount
      from qvm_new_apps.purchase_orders po
      join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = po.confirmed_order_id
      join classified s on s.quotation_id = co.quotation_id
      left join branch b on b.customer_id = s.branch_id
      join qvm_new_apps.purchase_items pi on pi.purchase_order_id = po.purchase_order_id
      left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id
     where po.created_at > v_to - interval '6 weeks' and po.created_at <= v_to
  ),
  spend_weeks as (
    select date_trunc('week', created_at) as week_start, sum(amount) as amount from spend_lines group by 1
  ),
  spend_cities as (
    select city, sum(amount) as amount from spend_lines group by city
  )
  select jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'kpis', (select jsonb_build_object('sent', sent, 'pending', pending, 'delivered', delivered, 'completed', completed) from kpi),
    'kpis_prev', case when v_prev_from is null then null else
                 (select jsonb_build_object('sent', sent, 'pending', pending, 'delivered', delivered, 'completed', completed) from kpi_prev) end,
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', branch_id, 'name', name, 'sent', sent, 'pending', pending,
                                                              'delivered', delivered, 'completed', completed) order by sent desc) from per_branch), '[]'::jsonb),
    'confirmation', jsonb_build_object(
       'avg_hours', (select round((avg(extract(epoch from (started_at - created_at)) / 3600.0))::numeric, 1) from confirmation),
       'n', (select count(*) from confirmation),
       'weekly', coalesce((select jsonb_agg(jsonb_build_object('week_start', week_start, 'avg_hours', round(avg_hours::numeric, 1), 'n', n) order by week_start) from confirmation_weeks), '[]'::jsonb)),
    'routes', coalesce((select jsonb_agg(jsonb_build_object('from_city', from_city, 'to_city', to_city, 'n', n, 'avg_days', round(avg_days::numeric, 1)) order by n desc)
                          from (select * from routes order by n desc limit 6) r), '[]'::jsonb),
    'cancellations', jsonb_build_object(
       'count', (select count(*) from cancelled),
       'value', (select coalesce(round(sum(value)::numeric, 2), 0) from cancelled),
       'reasons', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'count', n) order by n desc)
                              from (select reason, count(*) as n from cancelled group by reason) x), '[]'::jsonb)),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('branch_id', branch_id, 'name', name, 'count', n, 'value', round(value::numeric, 2)) order by n desc) from returned), '[]'::jsonb),
    'speed', jsonb_build_object(
       'avg_hours', (select round((avg(extract(epoch from (confirmed_at - priced_at)) / 3600.0))::numeric, 1) from speed),
       'n', (select count(*) from speed)),
    'signals', jsonb_build_object(
       'early_cancellations', (select count(*) filter (where not late) from cancels),
       'late_cancellations', (select count(*) filter (where late) from cancels),
       'late_additions', (select late from additions),
       'items_of_confirmed', (select items_total from additions),
       'late_addition_rate', (select case when items_total > 0 then round((late * 100.0 / items_total)::numeric, 1) else 0 end from additions),
       'internal_notes', (select n from internal_notes)),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('dow', dow, 'first', first_shift, 'second', second_shift) order by dow) from shifts), '[]'::jsonb),
    'spend', jsonb_build_object(
       'total', (select coalesce(round(sum(amount)::numeric, 2), 0) from spend_lines),
       'orders', (select count(distinct purchase_order_id) from spend_lines),
       'weekly', coalesce((select jsonb_agg(jsonb_build_object('week_start', week_start, 'amount', round(amount::numeric, 2)) order by week_start) from spend_weeks), '[]'::jsonb),
       'cities', coalesce((select jsonb_agg(jsonb_build_object('city', city, 'amount', round(amount::numeric, 2)) order by amount desc) from spend_cities), '[]'::jsonb))
  )) into v_result;

  return v_result;
end $function$;
