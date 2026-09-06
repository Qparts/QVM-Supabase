-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-1 — «إنشاء شحنة» from a delivery or a pickup, and the two actions on the board.
create or replace function qvm_new_apps.shipment_create(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_delivery integer := nullif(p_data->>'delivery_id','')::integer;
  v_pickup   bigint  := nullif(p_data->>'pickup_id','')::bigint;
  v_carrier  integer := nullif(p_data->>'carrier_id','')::integer;
  v_type     integer := nullif(p_data->>'ship_type_id','')::integer;
  v_addr     integer := nullif(p_data->>'dropoff_address_id','')::integer;
  v_id bigint; v_code text; v_order integer; v_branch bigint; v_n integer;
  v_enabled boolean;
begin
  if not v_team then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if num_nonnulls(v_delivery, v_pickup) <> 1 then
    return jsonb_build_object('status', false,
      'message', 'اختر إشعار تسليم أو عملية استلام — واحد منهما فقط', 'data', null);
  end if;

  -- A carrier switched off in settings is not an option. Checked here and not only in the
  -- dropdown, because the dropdown is the client's copy of the answer.
  if v_carrier is not null then
    select is_enabled into v_enabled from qvm_new_apps.shipping_settings where carrier_id = v_carrier;
    if not coalesce(v_enabled, false) then
      return jsonb_build_object('status', false,
        'message', 'شركة الشحن هذه غير مُفعَّلة في الإعدادات', 'data', null);
    end if;
  end if;

  -- One shipment per delivery or pickup. A second one would split the items and leave the
  -- board showing the same parts twice on two different vans.
  if exists (select 1 from qvm_new_apps.shipments s
              where (v_delivery is not null and s.delivery_id = v_delivery)
                 or (v_pickup is not null and s.pickup_id = v_pickup)) then
    return jsonb_build_object('status', false,
      'message', 'توجد شحنة بالفعل لهذا الإشعار — افتحها من اللوحة', 'data', null);
  end if;

  if v_delivery is not null then
    select d.confirmed_order_id into v_order
      from qvm_new_apps.deliveries d where d.delivery_id = v_delivery;
  else
    select po.confirmed_order_id, po.vendor_branch_id into v_order, v_branch
      from qvm_new_apps.pickups pk
      join qvm_new_apps.purchase_orders po on po.purchase_order_id = pk.purchase_order_id
     where pk.pickup_id = v_pickup;
  end if;

  insert into qvm_new_apps.shipments (
    shipment_code, delivery_id, pickup_id, confirmed_order_id,
    carrier_id, shipment_type_id,
    pickup_vendor_branch_id, pickup_address, pickup_phone,
    dropoff_address_id, dropoff_address, dropoff_contact, dropoff_phone,
    price, cost, notes, status_id, created_by)
  values (
    -- Readable and unique without a second sequence to keep in step.
    'SHP-' || to_char(now(), 'YYMM') || '-' || lpad(nextval('qvm_new_apps.shipments_shipment_id_seq')::text, 5, '0'),
    v_delivery, v_pickup, v_order,
    v_carrier, v_type,
    coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch),
    nullif(btrim(coalesce(p_data->>'pickup_address','')), ''),
    nullif(btrim(coalesce(p_data->>'pickup_phone','')), ''),
    v_addr,
    -- The address text is copied, not only referenced: a shipment has to still read
    -- correctly after somebody edits or retires the address record it came from.
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_address','')), ''),
             (select a.address_line || case when a.city is not null then ' — ' || a.city else '' end
                from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_contact','')), ''),
             (select a.contact_name from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_phone','')), ''),
             (select a.contact_phone from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    nullif(btrim(coalesce(p_data->>'price','')), '')::numeric,
    nullif(btrim(coalesce(p_data->>'cost','')), '')::numeric,
    nullif(btrim(coalesce(p_data->>'notes','')), ''),
    qvm_new_apps.shipment_status_id('Ready to Dispatch'),
    auth.uid())
  returning shipment_id, shipment_code into v_id, v_code;

  -- The contents come from the note itself rather than being chosen again: the quantities
  -- were already agreed there, and asking twice is how the two end up disagreeing.
  if v_delivery is not null then
    insert into qvm_new_apps.shipment_items (shipment_id, delivery_item_id, qty)
    select v_id, di.delivery_item_id, di.delivered_qty
      from qvm_new_apps.delivery_items di where di.delivery_id = v_delivery;
  else
    insert into qvm_new_apps.shipment_items (shipment_id, pickup_item_id, qty)
    select v_id, pi.pickup_item_id, pi.pickup_qty
      from qvm_new_apps.pickup_items pi where pi.pickup_id = v_pickup;
  end if;
  get diagnostics v_n = row_count;

  insert into qvm_new_apps.status_logs (shipment_id, item_status, status_changed_by, created_by)
  values (v_id, qvm_new_apps.shipment_status_id('Ready to Dispatch'), auth.uid(), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('shipment_id', v_id, 'code', v_code, 'items', v_n));
end
$function$;

-- «تأكيد الإرسال» — the button on the board.
create or replace function qvm_new_apps.shipment_dispatch(p_shipment_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_ship record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_ship from qvm_new_apps.shipments where shipment_id = p_shipment_id;
  if v_ship is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_ship.carrier_id is null then
    return jsonb_build_object('status', false,
      'message', 'اختر شركة الشحن قبل التأكيد', 'data', null);
  end if;

  perform qvm_new_apps.shipment_set_status(p_shipment_id, 'Dispatched');
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('shipment_id', p_shipment_id));
end
$function$;

-- «تعيين سائق» — only for our own agent, and only to somebody who actually is a driver.
create or replace function qvm_new_apps.shipment_assign_driver(p_shipment_id bigint, p_driver uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_carrier text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if p_driver is not null and not exists (
    select 1 from qvm_new_apps.user_data u
      join qvm_new_apps.list_data d on d.list_data_id = u.user_role
     where u.user_id = p_driver and d.list_id = 16 and d.list_data = 'Driver'
       and u.deleted_at is null) then
    return jsonb_build_object('status', false,
      'message', 'هذا المستخدم ليس سائقاً', 'data', null);
  end if;

  select d.list_data into v_carrier
    from qvm_new_apps.shipments s
    join qvm_new_apps.list_data d on d.list_data_id = s.carrier_id
   where s.shipment_id = p_shipment_id;

  -- A driver against Mrsool would put two carriers on one shipment and make the board lie
  -- about who is holding the part.
  if p_driver is not null and coalesce(v_carrier, '') <> 'Internal Agent' then
    return jsonb_build_object('status', false,
      'message', 'لا يمكن تعيين سائق إلا على شحنة شركتها «Internal Agent»', 'data', null);
  end if;

  update qvm_new_apps.shipments
     set driver_id = p_driver, updated_at = now()
   where shipment_id = p_shipment_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

revoke all on function qvm_new_apps.shipment_create(jsonb) from public;
revoke all on function qvm_new_apps.shipment_dispatch(bigint) from public;
revoke all on function qvm_new_apps.shipment_assign_driver(bigint, uuid) from public;
grant execute on function qvm_new_apps.shipment_create(jsonb) to authenticated;
grant execute on function qvm_new_apps.shipment_dispatch(bigint) to authenticated;
grant execute on function qvm_new_apps.shipment_assign_driver(bigint, uuid) to authenticated;
