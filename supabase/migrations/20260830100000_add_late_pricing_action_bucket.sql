-- Actions tab: new "Late Pricing" bucket — orders with at least one item still sitting at
-- Sent To Vendor (237) that no vendor has responded to (no quotation_vendor_items.cost) within
-- 24 hours of being sent. quotation_vendor_items.created_at defaults to now() at row-insert time,
-- i.e. exactly when create_vendors_quotations sent that item to that vendor.
--
-- Unlike fully_priced (which requires every relevant item on the order to already be resolved),
-- this bucket surfaces an order as soon as ANY item is overdue — the point is to prompt staff to
-- chase a specific vendor, not to gate on the whole order being otherwise done.
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

  select coalesce(jsonb_agg(to_jsonb(r) order by r.confirmation_date desc), '[]'::jsonb) into v_nopo
  from (
    select q.quotation_id, co.confirmed_order_id, q.order_number,
           co.created_at as confirmation_date,
           coalesce(cb.branch_name, '') as branch_name,
           (select count(*) from qvm_new_apps.confirmed_items ci where ci.confirmed_order_id = co.confirmed_order_id) as item_count
    from qvm_new_apps.confirmed_orders co
    join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
    left join lateral (
      select cb2.customer_id, cb2.branch_name
      from qvm_new_apps.quotation_items qi2
      join qvm_new_apps.client_branches cb2 on cb2.customer_id = qi2.customer_id
      where qi2.quotation_id = q.quotation_id
      limit 1
    ) cb on true
    where not exists (
      select 1 from qvm_new_apps.purchase_orders po
      where po.confirmed_order_id = co.confirmed_order_id
    )
    and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
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
end $function$
;
