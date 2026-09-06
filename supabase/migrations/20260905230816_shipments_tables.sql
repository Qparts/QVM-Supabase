-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-1 — a shipment as a thing, not a document.
--
-- Delivery already exists here as paperwork: `deliveries` is a signed note against a
-- confirmed order and `pickups` is a collection from a vendor branch. Neither says who is
-- carrying it, where it is now, or what it cost — so «where is my part» has been answered by
-- WhatsApp. A shipment is the movement itself, and the notes stay what they are: the proof
-- that it arrived.
--
-- One shipment carries either a delivery (to the customer) or a pickup (from the vendor). It
-- is not both, because the two have different ends and merging them would make every address
-- column mean two things.
create table if not exists qvm_new_apps.shipments (
  shipment_id      bigint generated always as identity primary key,
  shipment_code    text not null unique,

  -- What is being moved. Exactly one of these is set.
  delivery_id      integer references qvm_new_apps.deliveries(delivery_id) on delete restrict,
  pickup_id        bigint  references qvm_new_apps.pickups(pickup_id)      on delete restrict,
  confirmed_order_id integer references qvm_new_apps.confirmed_orders(confirmed_order_id) on delete restrict,

  -- Who moves it: a carrier from list 11, and a driver only when that carrier is our own.
  carrier_id       integer references qvm_new_apps.list_data(list_data_id),
  shipment_type_id integer references qvm_new_apps.list_data(list_data_id),
  driver_id        uuid    references qvm_new_apps.user_data(user_id),

  -- Both ends. The vendor branch is a row; the customer end is an address row from
  -- QNEW-123, with the text kept beside it so a shipment still reads correctly years later
  -- when the address record has been edited or deactivated.
  pickup_vendor_branch_id bigint references qvm_new_apps.vendor_branches(vendor_branch_id),
  pickup_address   text,
  pickup_phone     text,
  dropoff_address_id integer references qvm_new_apps.customer_addresses(address_id),
  dropoff_address  text,
  dropoff_contact  text,
  dropoff_phone    text,

  -- Money: what the customer is charged and what we pay the carrier. Kept apart because the
  -- margin between them is the number the business actually watches.
  price            numeric,
  cost             numeric,
  currency         text not null default 'SAR',

  -- The carrier's own reference and whatever it hands back, kept raw. A tracking page that
  -- cannot show the carrier's own words is a tracking page people stop trusting.
  tracking_ref     text,
  tracking_url     text,
  carrier_status   text,
  carrier_payload  jsonb,

  status_id        integer not null references qvm_new_apps.list_data(list_data_id),
  eta              timestamptz,
  dispatched_at    timestamptz,
  picked_up_at     timestamptz,
  delivered_at     timestamptz,
  failure_reason   text,

  -- Proof of delivery, written by the driver page (S-4).
  pod_signature    text,
  pod_photo_url    text,
  pod_receiver     text,

  notes            text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint shipments_one_subject
    check (num_nonnulls(delivery_id, pickup_id) = 1),
  -- A driver is our own agent. Naming one against Mrsool would put two carriers on one
  -- shipment and make the board lie about who has the part.
  constraint shipments_driver_needs_internal_carrier
    check (driver_id is null or carrier_id is not null)
);

create index if not exists shipments_status_idx   on qvm_new_apps.shipments(status_id);
create index if not exists shipments_driver_idx   on qvm_new_apps.shipments(driver_id);
create index if not exists shipments_order_idx    on qvm_new_apps.shipments(confirmed_order_id);
create index if not exists shipments_delivery_idx on qvm_new_apps.shipments(delivery_id);
create index if not exists shipments_pickup_idx   on qvm_new_apps.shipments(pickup_id);
create index if not exists shipments_tracking_idx on qvm_new_apps.shipments(tracking_ref);

-- What is in the box. Over `delivery_items` rather than duplicating the line: the quantity
-- delivered is already recorded there and two copies of it would disagree within a week.
create table if not exists qvm_new_apps.shipment_items (
  shipment_item_id bigint generated always as identity primary key,
  shipment_id      bigint not null references qvm_new_apps.shipments(shipment_id) on delete cascade,
  delivery_item_id integer references qvm_new_apps.delivery_items(delivery_item_id) on delete cascade,
  pickup_item_id   bigint  references qvm_new_apps.pickup_items(pickup_item_id) on delete cascade,
  qty              integer,
  created_at       timestamptz not null default now(),
  constraint shipment_items_one_subject check (num_nonnulls(delivery_item_id, pickup_item_id) = 1)
);

create index if not exists shipment_items_shipment_idx on qvm_new_apps.shipment_items(shipment_id);

-- S-1 requires every change in the status log. `status_logs` is item-scoped today and its
-- item columns are already nullable, so a shipment row joins the same timeline instead of
-- starting a second one nobody would think to read.
alter table qvm_new_apps.status_logs
  add column if not exists shipment_id bigint references qvm_new_apps.shipments(shipment_id) on delete cascade;

create index if not exists status_logs_shipment_idx on qvm_new_apps.status_logs(shipment_id);

alter table qvm_new_apps.shipments      enable row level security;
alter table qvm_new_apps.shipment_items enable row level security;
