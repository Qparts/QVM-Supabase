-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-3 — «إعدادات أنواع الشحن».
--
-- One row per carrier (list 11) and per delivery type (list 10), saying whether it is offered
-- at all and how its price is arrived at. Disabling a carrier here takes it out of the
-- create-order options and off the board, which is the whole point: the five carriers in
-- list 11 are what the business could use, not what it does use this month.
create table if not exists qvm_new_apps.shipping_settings (
  setting_id     bigint generated always as identity primary key,
  -- Exactly one of the two: this row is either about a carrier or about a delivery type.
  carrier_id     integer references qvm_new_apps.list_data(list_data_id),
  ship_type_id   integer references qvm_new_apps.list_data(list_data_id),
  is_enabled     boolean not null default true,
  -- live  = ask the carrier per shipment (Mrsool's calculate_price)
  -- flat  = one fee, in flat_fee
  -- manual= somebody types the cost on the shipment
  pricing_mode   text not null default 'manual' check (pricing_mode in ('live', 'flat', 'manual')),
  flat_fee       numeric,
  default_region_id integer,
  sort_order     integer not null default 0,
  updated_by     uuid,
  updated_at     timestamptz not null default now(),
  constraint shipping_settings_one_subject check (num_nonnulls(carrier_id, ship_type_id) = 1)
);

create unique index if not exists shipping_settings_carrier_uniq
  on qvm_new_apps.shipping_settings(carrier_id) where carrier_id is not null;
create unique index if not exists shipping_settings_type_uniq
  on qvm_new_apps.shipping_settings(ship_type_id) where ship_type_id is not null;

-- A global switch rather than a row per carrier: «هل نستخدم سائقينا أصلاً» is one answer,
-- and hiding the driver machinery until it is turned on keeps the board honest for the
-- workspaces that only ever hand shipments to a carrier.
create table if not exists qvm_new_apps.shipping_config (
  id                     boolean primary key default true check (id),
  internal_drivers_enabled boolean not null default false,
  updated_by             uuid,
  updated_at             timestamptz not null default now()
);

insert into qvm_new_apps.shipping_config (id) values (true) on conflict do nothing;

-- S-2 — carrier credentials.
--
-- The token never leaves the database: no RPC selects this table, RLS denies every web role,
-- and the Edge Function reads it as service_role. That is what «server-side only» has to mean
-- for a per-workspace credential — an environment variable cannot hold one per carrier per
-- environment, and a client bundle must never hold one at all.
create table if not exists qvm_new_apps.carrier_credentials (
  credential_id  bigint generated always as identity primary key,
  carrier_id     integer not null references qvm_new_apps.list_data(list_data_id),
  environment    text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  api_base_url   text,
  api_token      text,
  webhook_secret text,
  is_active      boolean not null default true,
  last_test_at   timestamptz,
  last_test_ok   boolean,
  last_test_note text,
  updated_by     uuid,
  updated_at     timestamptz not null default now(),
  unique (carrier_id, environment)
);

-- Seed the settings from the carriers and types that already exist, all disabled except the
-- ones the business already names on quotations. Nothing is invented: these are lists 10/11.
insert into qvm_new_apps.shipping_settings (carrier_id, is_enabled, pricing_mode, sort_order)
select d.list_data_id,
       d.list_data in ('Mrsool', 'Internal Agent'),
       case when d.list_data = 'Mrsool' then 'live' else 'manual' end,
       d.list_data_id
  from qvm_new_apps.list_data d
 where d.list_id = 11
   and not exists (select 1 from qvm_new_apps.shipping_settings s where s.carrier_id = d.list_data_id);

insert into qvm_new_apps.shipping_settings (ship_type_id, is_enabled, pricing_mode, sort_order)
select d.list_data_id, true, 'manual', d.list_data_id
  from qvm_new_apps.list_data d
 where d.list_id = 10
   and not exists (select 1 from qvm_new_apps.shipping_settings s where s.ship_type_id = d.list_data_id);

alter table qvm_new_apps.shipping_settings    enable row level security;
alter table qvm_new_apps.shipping_config      enable row level security;
alter table qvm_new_apps.carrier_credentials  enable row level security;
