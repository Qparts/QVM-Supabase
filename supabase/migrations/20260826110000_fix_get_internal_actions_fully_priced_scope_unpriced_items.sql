-- Fix: "Fully priced" was checking every item on the order (any status), so a single item that had
-- already moved past pricing (e.g. Confirmed/Processing) — completely irrelevant to "does this order
-- still need someone to set a selling price" — could block the whole order from ever qualifying.
-- Correct scope: only look at items still sitting *before* Priced (17) in the workflow — i.e. still
-- waiting on a selling price — using the same "less than priced" status set get_internal_dashboard's
-- v_rfq_statuses already encodes (217/218/236/237 and their legacy twins 216/235 minus 17 itself).
-- An order surfaces here when it has at least one such item and every one of them already has a
-- vendor cost back — nothing left to do except actually type in the sell price.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_actions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_delay_days int;
  v_ready jsonb; v_fully jsonb; v_sla jsonb; v_nopo jsonb;
  c_closed int[] := array[18, 23, 29, 30, 31, 268];
  c_less_than_priced int[] := array[216, 217, 218, 235, 236, 237];
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', null);
  end if;

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
      select cb2.branch_name
      from qvm_new_apps.quotation_items qi2
      join qvm_new_apps.client_branches cb2 on cb2.customer_id = qi2.customer_id
      where qi2.quotation_id = q.quotation_id
      limit 1
    ) cb on true
    where not exists (
      select 1 from qvm_new_apps.purchase_orders po
      where po.confirmed_order_id = co.confirmed_order_id
    )
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'sla_threshold_days', v_delay_days,
    'ready_for_quotation', v_ready,
    'fully_priced', v_fully,
    'exceeded_sla', v_sla,
    'confirmed_no_po', v_nopo
  ));
end $function$
;
