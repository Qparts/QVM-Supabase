-- Synced from QVM/test branch applied migration history (version 20260524123941, name: fix_change_item_status_bulk_parent_cte_visibility)
create or replace function public.change_item_status_bulk(
  p_quotation_item_ids integer[],
  p_new_status_id integer
)
returns jsonb
language plpgsql
security definer
set search_path = qvm_new_apps, public, pg_temp
as $function$
declare
  v_uid uuid;
  v_user_type int;
  v_new_status_label text;
  v_blocked_ids int[];
  v_any_blocked int;
  v_updated_q int;
  v_updated_c int;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  select user_type into v_user_type
  from user_data
  where user_id = v_uid;

  if v_user_type <> 185 then
    raise exception 'Access denied: Internal users only';
  end if;

  select ld.list_data
  into v_new_status_label
  from list_data ld
  where ld.list_data_id = p_new_status_id;

  if v_new_status_label is null then
    raise exception 'Invalid new status id %', p_new_status_id;
  end if;

  select array_agg(ld.list_data_id)
  into v_blocked_ids
  from list_data ld
  join lists l on l.list_id = ld.list_id
  where lower(l.list_name) in ('item_status', 'rfq_status', 'status')
    and lower(ld.list_data) in (
      'pending invoice',
      'pending credit note',
      'invoice issued',
      'credit note issued',
      'claim sent',
      'settled'
    );

  select count(*)
  into v_any_blocked
  from (
    select qi.item_status as st
    from quotation_items qi
    where qi.quotation_item_id = any(p_quotation_item_ids)
    union all
    select ci.item_status as st
    from confirmed_items ci
    where ci.quotation_item_id = any(p_quotation_item_ids)
  ) s
  where s.st = any(v_blocked_ids);

  if coalesce(v_any_blocked, 0) > 0 then
    raise exception 'Selected items cannot be updated because their current status does not allow changes.';
  end if;

  with q_to_update as (
    select qi.quotation_item_id
    from quotation_items qi
    left join confirmed_items ci on ci.quotation_item_id = qi.quotation_item_id
    where qi.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is null
  )
  update quotation_items qi
  set item_status = p_new_status_id
  from q_to_update u
  where qi.quotation_item_id = u.quotation_item_id;
  get diagnostics v_updated_q = row_count;

  insert into status_logs (quotation_item_id, item_status, status_changed_by)
  select u.quotation_item_id, p_new_status_id, v_uid
  from (
    select qi.quotation_item_id
    from quotation_items qi
    left join confirmed_items ci on ci.quotation_item_id = qi.quotation_item_id
    where qi.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is null
  ) u;

  with c_to_update as (
    select ci.confirmed_item_id
    from confirmed_items ci
    where ci.quotation_item_id = any(p_quotation_item_ids)
  )
  update confirmed_items ci
  set item_status = p_new_status_id
  from c_to_update u
  where ci.confirmed_item_id = u.confirmed_item_id;
  get diagnostics v_updated_c = row_count;

  insert into status_logs (confirmed_item_id, item_status, status_changed_by)
  select ci.confirmed_item_id, p_new_status_id, v_uid
  from confirmed_items ci
  where ci.quotation_item_id = any(p_quotation_item_ids);

  if lower(trim(v_new_status_label)) = 'delivered' then
    with target_confirmed as (
      select
        ci.confirmed_item_id,
        ci.confirmed_order_id,
        greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) as delivery_qty
      from confirmed_items ci
      join quotation_items qi
        on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id
      from target_confirmed tc
    ),
    inserted_deliveries as (
      insert into deliveries (confirmed_order_id)
      select to2.confirmed_order_id
      from target_orders to2
      where not exists (
        select 1
        from deliveries d
        where d.confirmed_order_id = to2.confirmed_order_id
      )
      returning delivery_id, confirmed_order_id
    ),
    resolved_deliveries as (
      select id.confirmed_order_id, id.delivery_id
      from inserted_deliveries id
      union all
      select distinct on (d.confirmed_order_id)
        d.confirmed_order_id,
        d.delivery_id
      from deliveries d
      join target_orders to2
        on to2.confirmed_order_id = d.confirmed_order_id
      order by d.confirmed_order_id, d.created_at asc nulls last, d.delivery_id asc
    )
    insert into delivery_items (
      delivery_id,
      confirmed_item_id,
      delivered_qty,
      received_qty
    )
    select
      rd.delivery_id,
      tc.confirmed_item_id,
      tc.delivery_qty,
      tc.delivery_qty
    from target_confirmed tc
    join resolved_deliveries rd
      on rd.confirmed_order_id = tc.confirmed_order_id
    where not exists (
      select 1
      from delivery_items di
      join deliveries d2 on d2.delivery_id = di.delivery_id
      where d2.confirmed_order_id = tc.confirmed_order_id
        and di.confirmed_item_id = tc.confirmed_item_id
    );
  elsif lower(trim(v_new_status_label)) = 'return' then
    with target_confirmed as (
      select
        ci.confirmed_item_id,
        ci.confirmed_order_id,
        greatest(coalesce(ci.requested_return_qty, ci.approved_qty, qi.quantity, 1), 1) as item_return_qty
      from confirmed_items ci
      join quotation_items qi
        on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id
      from target_confirmed tc
    ),
    inserted_returns as (
      insert into returns (confirmed_order_id)
      select to2.confirmed_order_id
      from target_orders to2
      where not exists (
        select 1
        from returns r
        where r.confirmed_order_id = to2.confirmed_order_id
      )
      returning return_id, confirmed_order_id
    ),
    resolved_returns as (
      select ir.confirmed_order_id, ir.return_id
      from inserted_returns ir
      union all
      select distinct on (r.confirmed_order_id)
        r.confirmed_order_id,
        r.return_id
      from returns r
      join target_orders to2
        on to2.confirmed_order_id = r.confirmed_order_id
      order by r.confirmed_order_id, r.created_at asc nulls last, r.return_id asc
    )
    insert into return_items (
      return_id,
      confirmed_item_id,
      return_qty
    )
    select
      rr.return_id,
      tc.confirmed_item_id,
      tc.item_return_qty
    from target_confirmed tc
    join resolved_returns rr
      on rr.confirmed_order_id = tc.confirmed_order_id
    where not exists (
      select 1
      from return_items ri
      join returns r2 on r2.return_id = ri.return_id
      where r2.confirmed_order_id = tc.confirmed_order_id
        and ri.confirmed_item_id = tc.confirmed_item_id
    );
  end if;

  return jsonb_build_object(
    'status', 'success',
    'message', 'Statuses updated successfully',
    'updated_count', coalesce(v_updated_q, 0) + coalesce(v_updated_c, 0)
  );
end;
$function$;

revoke execute on function public.change_item_status_bulk(integer[], integer) from public, anon;
grant execute on function public.change_item_status_bulk(integer[], integer) to authenticated;

with orphan_deliveries as (
  select d.delivery_id, d.confirmed_order_id
  from qvm_new_apps.deliveries d
  left join qvm_new_apps.delivery_items di on di.delivery_id = d.delivery_id
  group by d.delivery_id, d.confirmed_order_id
  having count(di.delivery_item_id) = 0
),
delivered_confirmed_items as (
  select
    od.delivery_id,
    ci.confirmed_item_id,
    greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) as delivery_qty
  from orphan_deliveries od
  join qvm_new_apps.confirmed_items ci
    on ci.confirmed_order_id = od.confirmed_order_id
  join qvm_new_apps.quotation_items qi
    on qi.quotation_item_id = ci.quotation_item_id
  join qvm_new_apps.list_data ld
    on ld.list_data_id = ci.item_status
  where lower(trim(ld.list_data)) = 'delivered'
)
insert into qvm_new_apps.delivery_items (
  delivery_id,
  confirmed_item_id,
  delivered_qty,
  received_qty
)
select
  dci.delivery_id,
  dci.confirmed_item_id,
  dci.delivery_qty,
  dci.delivery_qty
from delivered_confirmed_items dci
where not exists (
  select 1
  from qvm_new_apps.delivery_items di
  where di.delivery_id = dci.delivery_id
    and di.confirmed_item_id = dci.confirmed_item_id
);

with orphan_returns as (
  select r.return_id, r.confirmed_order_id
  from qvm_new_apps.returns r
  left join qvm_new_apps.return_items ri on ri.return_id = r.return_id
  group by r.return_id, r.confirmed_order_id
  having count(ri.return_item_id) = 0
),
returned_confirmed_items as (
  select
    or2.return_id,
    ci.confirmed_item_id,
    greatest(coalesce(ci.requested_return_qty, ci.approved_qty, qi.quantity, 1), 1) as item_return_qty
  from orphan_returns or2
  join qvm_new_apps.confirmed_items ci
    on ci.confirmed_order_id = or2.confirmed_order_id
  join qvm_new_apps.quotation_items qi
    on qi.quotation_item_id = ci.quotation_item_id
  join qvm_new_apps.list_data ld
    on ld.list_data_id = ci.item_status
  where lower(trim(ld.list_data)) = 'return'
)
insert into qvm_new_apps.return_items (
  return_id,
  confirmed_item_id,
  return_qty
)
select
  rci.return_id,
  rci.confirmed_item_id,
  rci.item_return_qty
from returned_confirmed_items rci
where not exists (
  select 1
  from qvm_new_apps.return_items ri
  where ri.return_id = rci.return_id
    and ri.confirmed_item_id = rci.confirmed_item_id
);;
