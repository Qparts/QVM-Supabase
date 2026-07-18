-- Synced from QVM/test branch applied migration history (version 20260621051137, name: fix_change_item_status_bulk_delivery_notes_vat)
CREATE OR REPLACE FUNCTION public.change_item_status_bulk(p_quotation_item_ids integer[], p_new_status_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
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
      join quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id from target_confirmed tc
    ),
    inserted_deliveries as (
      insert into deliveries (confirmed_order_id)
      select to2.confirmed_order_id from target_orders to2
      where not exists (
        select 1 from deliveries d where d.confirmed_order_id = to2.confirmed_order_id
      )
      returning delivery_id, confirmed_order_id
    ),
    resolved_deliveries as (
      select
        to2.confirmed_order_id,
        coalesce(id.delivery_id, existing_delivery.delivery_id) as delivery_id
      from target_orders to2
      left join inserted_deliveries id on id.confirmed_order_id = to2.confirmed_order_id
      left join lateral (
        select d_existing.delivery_id
        from deliveries d_existing
        where d_existing.confirmed_order_id = to2.confirmed_order_id
        order by d_existing.created_at asc nulls last, d_existing.delivery_id asc
        limit 1
      ) existing_delivery on true
    )
    insert into delivery_items (delivery_id, confirmed_item_id, delivered_qty, received_qty)
    select rd.delivery_id, tc.confirmed_item_id, tc.delivery_qty, tc.delivery_qty
    from target_confirmed tc
    join resolved_deliveries rd on rd.confirmed_order_id = tc.confirmed_order_id
    where rd.delivery_id is not null
      and not exists (
        select 1
        from delivery_items di
        join deliveries d2 on d2.delivery_id = di.delivery_id
        where d2.confirmed_order_id = tc.confirmed_order_id
          and di.confirmed_item_id = tc.confirmed_item_id
      );

    -- Populate delivery_notes so the Delivered Orders page can display them
    insert into delivery_notes (
      order_number, client_name, branch, confirmation_date, delivery_date,
      final_part_number, part_description, main_brand, model, brand_class,
      vin, plate_number, approved_quantity,
      price_before_vat, total_price_before_vat,
      vat, total_price_including_vat,
      confirmed_item_id, created_at, updated_at
    )
    select
      q.order_number,
      coalesce(ld_client.list_data, ''),
      coalesce(cb.branch_name, ''),
      co.created_at,
      now()::date,
      coalesce(ci.final_part_number, qi.part_number, qi.alternative_part_number, ''),
      coalesce(qi.part_description, ''),
      coalesce(ld_brand.list_data, ''),
      coalesce(qi.model, ''),
      coalesce(ld_bc.list_data, ''),
      coalesce(qi.vin, ''),
      coalesce(q.plate_number, ''),
      greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1),
      coalesce(qi.price_before_vat, 0),
      coalesce(qi.total_price_before_vat, 0),
      round((coalesce(qi.price_before_vat, 0) * 0.15)::numeric, 2),
      round((coalesce(qi.price_before_vat, 0) * 1.15)::numeric, 2),
      ci.confirmed_item_id,
      now(),
      now()
    from confirmed_items ci
    join quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    join confirmed_orders co on co.confirmed_order_id = ci.confirmed_order_id
    join quotations q on q.quotation_id = co.quotation_id
    left join client_branches cb on cb.customer_id = qi.customer_id
    left join list_data ld_client on ld_client.list_data_id = cb.list_data_id
    left join list_data ld_brand on ld_brand.list_data_id = qi.main_brand
    left join list_data ld_bc on ld_bc.list_data_id = qi.brand_class
    where ci.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is not null
    on conflict (confirmed_item_id) do update set
      delivery_date = now()::date,
      vat = round((coalesce(excluded.price_before_vat, 0) * 0.15)::numeric, 2),
      total_price_including_vat = round((coalesce(excluded.price_before_vat, 0) * 1.15)::numeric, 2),
      updated_at = now();

  elsif lower(trim(v_new_status_label)) = 'return' then
    with target_confirmed as (
      select
        ci.confirmed_item_id,
        ci.confirmed_order_id,
        greatest(coalesce(ci.requested_return_qty, ci.approved_qty, qi.quantity, 1), 1) as item_return_qty
      from confirmed_items ci
      join quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id from target_confirmed tc
    ),
    inserted_returns as (
      insert into returns (confirmed_order_id)
      select to2.confirmed_order_id from target_orders to2
      where not exists (
        select 1 from returns r where r.confirmed_order_id = to2.confirmed_order_id
      )
      returning return_id, confirmed_order_id
    ),
    resolved_returns as (
      select
        to2.confirmed_order_id,
        coalesce(ir.return_id, existing_return.return_id) as return_id
      from target_orders to2
      left join inserted_returns ir on ir.confirmed_order_id = to2.confirmed_order_id
      left join lateral (
        select r_existing.return_id
        from returns r_existing
        where r_existing.confirmed_order_id = to2.confirmed_order_id
        order by r_existing.created_at asc nulls last, r_existing.return_id asc
        limit 1
      ) existing_return on true
    )
    insert into return_items (return_id, confirmed_item_id, return_qty)
    select rr.return_id, tc.confirmed_item_id, tc.item_return_qty
    from target_confirmed tc
    join resolved_returns rr on rr.confirmed_order_id = tc.confirmed_order_id
    where rr.return_id is not null
      and not exists (
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
$function$;;
