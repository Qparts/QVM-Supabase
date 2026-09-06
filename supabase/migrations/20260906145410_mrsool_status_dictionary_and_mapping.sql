-- QNEW-124 S-2 / QQ2-79 — Mrsool's fourteen statuses, as data.
--
-- Read from the LaaS v1 spec (logistics.staging.mrsool.co, OrderSerializer.status). The
-- design reserved a slot for them and never listed them; this is the list.
--
-- They go in their own list rather than being merged into ours, because they are Mrsool's
-- vocabulary and not ours: our board shows our seven, and this list is what an incoming
-- webhook is validated against and what the status guide displays.
do $mig$
declare v_list integer;
begin
  select list_id into v_list from qvm_new_apps.lists where list_name = 'mrsool_status';
  if v_list is null then
    insert into qvm_new_apps.lists (list_name) values ('mrsool_status') returning list_id into v_list;
  end if;

  insert into qvm_new_apps.list_data (list_id, list_data)
  select v_list, v.name from (values
    ('COURIER_PENDING'), ('COURIER_ASSIGNED'), ('COURIER_REASSIGNED'),
    ('PICKUP_ARRIVED'), ('COLLECTING'), ('CONFIRMED_PICKUP'),
    ('WAITING_FOR_DELIVERY'), ('DELIVERING'), ('DROPOFF_ARRIVED'),
    ('PARTIALLY_DELIVERED'), ('DELIVERED'), ('RETURN'), ('CANCELED'), ('EXPIRED')
  ) v(name)
  where not exists (select 1 from qvm_new_apps.list_data d
                     where d.list_id = v_list and d.list_data = v.name);
end
$mig$;

-- Carrier vocabulary in, ours out.
--
-- A table rather than a CASE in a function: when Mrsool adds a fifteenth status, or another
-- carrier arrives with its own words, this is a row — not a deploy.
create table if not exists qvm_new_apps.carrier_status_map (
  map_id         bigint generated always as identity primary key,
  carrier_id     integer not null references qvm_new_apps.list_data(list_data_id),
  carrier_status text not null,
  our_status_id  integer not null references qvm_new_apps.list_data(list_data_id),
  -- Ordering matters when two carrier statuses map to one of ours: the later one must not
  -- pull a shipment backwards. Higher wins.
  rank           integer not null default 0,
  unique (carrier_id, carrier_status)
);

alter table qvm_new_apps.carrier_status_map enable row level security;

do $seed$
declare v_mrsool integer;
begin
  select list_data_id into v_mrsool from qvm_new_apps.list_data
   where list_id = 11 and list_data = 'Mrsool';

  insert into qvm_new_apps.carrier_status_map (carrier_id, carrier_status, our_status_id, rank)
  select v_mrsool, m.cs, qvm_new_apps.shipment_status_id(m.ours), m.rk
  from (values
    -- looking for a courier, and courier assigned: it has left us either way
    ('COURIER_PENDING',      'Dispatched',       10),
    ('COURIER_ASSIGNED',     'Dispatched',       11),
    ('COURIER_REASSIGNED',   'Dispatched',       12),
    -- at the shop, collecting, collected
    ('PICKUP_ARRIVED',       'Dispatched',       20),
    ('COLLECTING',           'Picked Up',        21),
    ('CONFIRMED_PICKUP',     'Picked Up',        22),
    -- moving
    ('WAITING_FOR_DELIVERY', 'In Transit',       30),
    ('DELIVERING',           'In Transit',       31),
    ('DROPOFF_ARRIVED',      'Out for Delivery', 32),
    -- ends. Partially delivered counts as delivered here and the shortfall shows on the
    -- delivery note, which is where a short delivery is already reconciled.
    ('PARTIALLY_DELIVERED',  'Delivered',        40),
    ('DELIVERED',            'Delivered',        41),
    ('RETURN',               'Returned',         42),
    ('CANCELED',             'Cancelled',        43),
    -- expired means nobody ever took it, so it never shipped
    ('EXPIRED',              'Cancelled',        44)
  ) m(cs, ours, rk)
  where v_mrsool is not null
    and not exists (select 1 from qvm_new_apps.carrier_status_map x
                     where x.carrier_id = v_mrsool and x.carrier_status = m.cs);
end
$seed$;
