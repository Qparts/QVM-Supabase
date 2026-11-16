-- Actions tab, Confirmed - no PO: line by line, not order by order.
--
-- An order dropped out of the bucket as soon as it had any purchase order, so a line confirmed
-- after the first purchase order (or left off it) never showed: on QVM/test 138 orders have a
-- purchase order and still a confirmed line with none, AMS-SHRYD-CA4DB94C among them. Now an
-- order shows while one of its lines is Confirmed, or Processing with no purchase order behind it,
-- and no vendor purchase order has that line. The row also carries waiting_item_ids, so the page
-- can show just those lines, and its date is when the oldest of them was confirmed.
--
-- Function body is the live one on QVM/test with only the confirmed_no_po query replaced.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_actions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_delay_days int;
  v_ready jsonb; v_fully jsonb; v_sla jsonb; v_nopo jsonb; v_late jsonb;
  c_closed int[] := array[18, 23, 29, 30, 31, 268];
  c_less_than_priced int[] := array[216, 217, 218, 235, 236, 237];
  v_branch_scope integer[];
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', null);
  end if;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  -- report_settings_thresholds.value is numeric
  select value::int into v_delay_days
  from qvm_new_apps.report_settings_thresholds where key = 'order_delay_threshold_days';
  v_delay_days := coalesce(v_delay_days, 3);

  select coalesce(jsonb_agg(to_jsonb(r) order by r.rfq_date desc), '[]'::jsonb) into v_ready
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) as item_count
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where qi.item_status = 235
      and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.rfq_date desc), '[]'::jsonb) into v_fully
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) filter (where qi.item_status = any(c_less_than_priced)) as sent_count,
           count(*) filter (where qi.item_status = any(c_less_than_priced) and exists (
             select 1 from qvm_new_apps.quotation_vendor_items qvi
             where qvi.quotation_item_id = qi.quotation_item_id and qvi.cost is not null and qvi.cost > 0
           )) as priced_count
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
    having count(*) filter (where qi.item_status = any(c_less_than_priced)) > 0
       and count(*) filter (where qi.item_status = any(c_less_than_priced)) = count(*) filter (where qi.item_status = any(c_less_than_priced) and exists (
             select 1 from qvm_new_apps.quotation_vendor_items qvi
             where qvi.quotation_item_id = qi.quotation_item_id and qvi.cost is not null and qvi.cost > 0
           ))
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.age_days desc), '[]'::jsonb) into v_sla
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) as open_items,
           floor(extract(epoch from (now() - q.created_at)) / 86400)::int as age_days
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where not (qi.item_status = any(c_closed))
      and q.created_at < now() - make_interval(days => v_delay_days)
      and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
  ) r;

  -- Confirmed - no PO, line by line: an order shows while one of its confirmed lines has nothing
  -- buying it. A line waits when it is Confirmed, or Processing with no purchase order behind it
  -- (one removed from under it), and no vendor purchase order has it. Uploading an invoice makes a
  -- purchase order with no vendor; that isn't a purchase. The date is when the oldest waiting line
  -- was confirmed; item_count and waiting_item_ids are the waiting lines.
  select coalesce(jsonb_agg(to_jsonb(r) order by r.confirmation_date desc), '[]'::jsonb) into v_nopo
  from (
    select q.quotation_id, co.confirmed_order_id, q.order_number,
           w.first_confirmed_at as confirmation_date,
           coalesce(cb.branch_name, '') as branch_name,
           w.item_count,
           w.waiting_item_ids
    from qvm_new_apps.confirmed_orders co
    join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
    join lateral (
      select count(*) as item_count,
             min(ci.created_at) as first_confirmed_at,
             array_agg(ci.quotation_item_id order by ci.quotation_item_id) as waiting_item_ids
      from qvm_new_apps.confirmed_items ci
      join qvm_new_apps.quotation_items qi3 on qi3.quotation_item_id = ci.quotation_item_id
      where ci.confirmed_order_id = co.confirmed_order_id
        and qi3.item_status in (19, 21)
        and not exists (
          select 1
          from qvm_new_apps.purchase_items pi
          join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
          where pi.confirmed_item_id = ci.confirmed_item_id
            and po.vendor_id is not null
        )
    ) w on w.item_count > 0
    left join lateral (
      select cb2.customer_id, cb2.branch_name
      from qvm_new_apps.quotation_items qi2
      join qvm_new_apps.client_branches cb2 on cb2.customer_id = qi2.customer_id
      where qi2.quotation_id = q.quotation_id
      limit 1
    ) cb on true
    where (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.oldest_sent_at asc), '[]'::jsonb) into v_late
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) as item_count,
           min(qvi_first.first_sent_at) as oldest_sent_at,
           floor(extract(epoch from (now() - min(qvi_first.first_sent_at))) / 3600)::int as hours_late
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    cross join lateral (
      select min(qvi.created_at) as first_sent_at
      from qvm_new_apps.quotation_vendor_items qvi
      where qvi.quotation_item_id = qi.quotation_item_id
    ) qvi_first
    where qi.item_status = 237
      and qvi_first.first_sent_at is not null
      and qvi_first.first_sent_at < now() - interval '24 hours'
      and not exists (
        select 1 from qvm_new_apps.quotation_vendor_items qvi2
        where qvi2.quotation_item_id = qi.quotation_item_id and qvi2.cost is not null and qvi2.cost > 0
      )
      and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'sla_threshold_days', v_delay_days,
    'ready_for_quotation', v_ready,
    'fully_priced', v_fully,
    'exceeded_sla', v_sla,
    'confirmed_no_po', v_nopo,
    'late_pricing', v_late
  ));
end $function$;

notify pgrst, 'reload schema';
