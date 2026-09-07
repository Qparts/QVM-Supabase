-- A pickup starts from the vendor, not from a pickup record that nobody has created yet.
--
-- The create-shipment form offered a «Pickup» dropdown fed from qvm_new_apps.pickups — a table
-- with zero rows in it, so the tab was permanently empty and there was no screen anywhere that
-- filled it. The thing a person actually knows when they send a van is the vendor: «go to
-- Petromin and collect whatever they still owe us». So the form now asks for the vendor, and
-- the orders it then offers are the ones the receipt screen marked «لم يُستلم».
--
-- One trip collects several orders, which is why the selection is a list. That means a pickup
-- can now span more than one purchase order, and pickups.purchase_order_id can only name one
-- of them — hence this table. The column keeps naming the first, so everything already joining
-- through it keeps working.
create table if not exists qvm_new_apps.pickup_orders (
  pickup_id         bigint not null references qvm_new_apps.pickups(pickup_id) on delete cascade,
  purchase_order_id bigint not null references qvm_new_apps.purchase_orders(purchase_order_id),
  created_at        timestamptz not null default now(),
  primary key (pickup_id, purchase_order_id)
);

-- Reached only through the SECURITY DEFINER functions below, like every other table here.
alter table qvm_new_apps.pickup_orders enable row level security;

-- What the vendor tab offers: the vendors who are still holding parts, and — once one is
-- chosen — that vendor's orders.
--
-- «Still holding» is decided by the item, not the order: an order counts only while it has an
-- item the receipt screen marked not_received AND that item is not already on a pickup. So an
-- order half-collected last week shows with the remainder, and an order fully collected stops
-- showing without anybody having to close it by hand.
create or replace function qvm_new_apps.shipment_pickup_sources(
  p_search text default null,
  p_vendor integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'vendors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vendor_id', s.vendor_id,
               'vendor_name', s.vendor_name,
               'orders', s.orders,
               'items', s.items)
             order by s.vendor_name)
        from (
          select v.vendor_id,
                 coalesce(v.vendor_name, v.zoho_name, '#' || v.vendor_id) as vendor_name,
                 count(distinct pi.purchase_order_id) as orders,
                 count(*) as items
            from qvm_new_apps.purchase_items pi
            join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
            join qvm_new_apps.vendors v on v.vendor_id = po.vendor_id
           where pi.receipt_status = 'not_received'
             and not exists (select 1 from qvm_new_apps.pickup_items pk
                              where pk.purchase_item_id = pi.purchase_item_id)
             and (v_search is null
                  or coalesce(v.vendor_name, v.zoho_name, '') ilike '%' || v_search || '%')
           group by v.vendor_id, coalesce(v.vendor_name, v.zoho_name, '#' || v.vendor_id)
        ) s), '[]'::jsonb),

    'orders', case when p_vendor is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'purchase_order_id', po.purchase_order_id,
               'order_id', po.confirmed_order_id,
               'invoice_number', po.vendor_invoice_number,
               'date', po.created_at,
               'branch_id', po.vendor_branch_id,
               'branch', vb.branch_name,
               'city', vb.city,
               'items', cnt.n)
             order by po.purchase_order_id desc)
        from qvm_new_apps.purchase_orders po
        left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = po.vendor_branch_id
        join lateral (
          select count(*) as n
            from qvm_new_apps.purchase_items pi
           where pi.purchase_order_id = po.purchase_order_id
             and pi.receipt_status = 'not_received'
             and not exists (select 1 from qvm_new_apps.pickup_items pk
                              where pk.purchase_item_id = pi.purchase_item_id)
        ) cnt on cnt.n > 0
       where po.vendor_id = p_vendor), '[]'::jsonb) end
  ));
end
$function$;

revoke all on function qvm_new_apps.shipment_pickup_sources(text, integer) from public;
grant execute on function qvm_new_apps.shipment_pickup_sources(text, integer) to authenticated;

-- shipment_create, extended with the third way of starting one: a set of purchase orders.
--
-- The delivery and single-pickup paths are untouched. The new path builds the pickup the old
-- one used to require someone else to have built, then rejoins the same code — so the board,
-- the tracking drawer and dispatch all see an ordinary pickup shipment and needed no changes.
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
  v_orders bigint[];
  v_vendors integer; v_vendor integer; v_branches integer;
  v_id bigint; v_code text; v_order integer; v_branch bigint; v_n integer;
  v_enabled boolean;
begin
  if not v_team then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- The client coerces every field to a string before sending, so the same list arrives as a
  -- JSON array from one caller and as «13526,13530» from another. Both are read here rather
  -- than making the two callers agree about something neither of them can see.
  if jsonb_typeof(p_data->'purchase_order_ids') = 'array' then
    select array_agg(x::bigint) into v_orders
      from jsonb_array_elements_text(p_data->'purchase_order_ids') x
     where btrim(x) <> '';
  elsif nullif(btrim(coalesce(p_data->>'purchase_order_ids','')), '') is not null then
    select array_agg(btrim(x)::bigint) into v_orders
      from unnest(string_to_array(p_data->>'purchase_order_ids', ',')) x
     where btrim(x) <> '';
  end if;

  if num_nonnulls(v_delivery, v_pickup, v_orders) <> 1 then
    return jsonb_build_object('status', false,
      'message', 'اختر إشعار تسليم أو أوامر شراء للاستلام — واحد منهما فقط', 'data', null);
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

  -- Building the pickup from the chosen orders.
  if v_orders is not null then
    -- One van goes to one vendor. Two vendors in a selection is a mistake the form should not
    -- have allowed, and silently creating one shipment for both would send it to one address.
    select count(distinct po.vendor_id), min(po.vendor_id),
           count(distinct po.vendor_branch_id), min(po.vendor_branch_id),
           min(po.confirmed_order_id)
      into v_vendors, v_vendor, v_branches, v_branch, v_order
      from qvm_new_apps.purchase_orders po
     where po.purchase_order_id = any(v_orders);

    if coalesce(v_vendors, 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'أوامر الشراء المختارة غير موجودة', 'data', null);
    end if;
    if v_vendors > 1 then
      return jsonb_build_object('status', false,
        'message', 'كل الأوامر في الشحنة الواحدة لازم تكون لنفس المورد', 'data', null);
    end if;
    -- More than one branch means more than one address to collect from. The shipment keeps no
    -- branch rather than claiming a wrong one, and the address field is then filled by hand.
    if coalesce(v_branches, 0) > 1 then v_branch := null; end if;

    -- Asked before anything is written. A `return` inside this function does not roll the
    -- statement back, so refusing after creating the pickup would leave an empty one behind
    -- for every rejected attempt.
    if not exists (
      select 1 from qvm_new_apps.purchase_items pi
       where pi.purchase_order_id = any(v_orders)
         and pi.receipt_status = 'not_received'
         and not exists (select 1 from qvm_new_apps.pickup_items pk
                          where pk.purchase_item_id = pi.purchase_item_id)) then
      return jsonb_build_object('status', false,
        'message', 'مفيش أصناف غير مستلمة في الأوامر المختارة', 'data', null);
    end if;

    insert into qvm_new_apps.pickups (purchase_order_id, pickup_date)
    values (v_orders[1], now())
    returning pickup_id into v_pickup;

    insert into qvm_new_apps.pickup_orders (pickup_id, purchase_order_id)
    select v_pickup, x from unnest(v_orders) x;

    -- Only the items still owed, and only the quantity still owed. An item already on another
    -- pickup is excluded so two vans are never sent for the same part.
    insert into qvm_new_apps.pickup_items (pickup_id, purchase_item_id, pickup_qty, created_by)
    select v_pickup, pi.purchase_item_id,
           greatest(coalesce(pi.approved_qty, 0) - coalesce(pi.received_qty, 0), 0),
           auth.uid()
      from qvm_new_apps.purchase_items pi
     where pi.purchase_order_id = any(v_orders)
       and pi.receipt_status = 'not_received'
       and not exists (select 1 from qvm_new_apps.pickup_items pk
                        where pk.purchase_item_id = pi.purchase_item_id);
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
  elsif v_orders is null then
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
    -- Placeholder; replaced below with a code built from this row's own id, so the two
    -- can never drift apart the way a second sequence would let them.
    'SHP-PENDING-' || gen_random_uuid()::text,
    v_delivery, v_pickup, v_order,
    v_carrier, v_type,
    coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch),
    -- The branch's own address and phone, when the form did not type one: a pickup with no
    -- address is a driver phoning the office to ask where he is going.
    coalesce(nullif(btrim(coalesce(p_data->>'pickup_address','')), ''),
             (select vb.address || case when vb.city is not null then ' — ' || vb.city else '' end
                from qvm_new_apps.vendor_branches vb
               where vb.vendor_branch_id = coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch))),
    coalesce(nullif(btrim(coalesce(p_data->>'pickup_phone','')), ''),
             (select vb.phone from qvm_new_apps.vendor_branches vb
               where vb.vendor_branch_id = coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch))),
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
  returning shipment_id into v_id;

  v_code := 'SHP-' || to_char(now(), 'YYMM') || '-' || lpad(v_id::text, 5, '0');
  update qvm_new_apps.shipments set shipment_code = v_code where shipment_id = v_id;

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
