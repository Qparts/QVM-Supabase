-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Bringing the test database up to what production runs. The two branches do not replicate to each
-- other in practice, so everything from 28 Aug onward has to be replayed here explicitly.

-- ① how a template is described on the upload screen
alter table qvm_new_apps.upload_templates
  add column if not exists icon          text,
  add column if not exists note_ar       text,
  add column if not exists note_en       text,
  add column if not exists warn_ar       text,
  add column if not exists warn_en       text,
  add column if not exists sheets_ar     text,
  add column if not exists sheets_en     text,
  add column if not exists lands         text,
  add column if not exists screen_fields jsonb not null default '[]'::jsonb;

-- ② values that belong to the file rather than to a row
alter table qvm_new_apps.upload_batches
  add column if not exists params jsonb not null default '{}'::jsonb;

-- ③ bilingual names, and the flag for a name this system worked out rather than read
alter table qvm_new_apps.upload_rows
  add column if not exists source_name_en text,
  add column if not exists clean_name_en  text,
  add column if not exists name_is_guess  boolean not null default false;

alter table qvm_new_apps.inventory_stock
  add column if not exists source_name_en text,
  add column if not exists clean_name_en  text,
  add column if not exists name_is_guess  boolean not null default false;

-- ④ homes for the template columns that used to land nowhere
alter table qvm_new_apps.agency_price_reference add column if not exists expires_on       date;
alter table qvm_new_apps.part_purchase_history  add column if not exists city             text;
alter table qvm_new_apps.part_purchase_history  add column if not exists qty              integer;
alter table qvm_new_apps.group_import_requests  add column if not exists request_end_date date;
alter table qvm_new_apps.group_import_requests  add column if not exists brand            text;
alter table qvm_new_apps.group_import_requests  add column if not exists part_class       text;
alter table qvm_new_apps.part_offers            add column if not exists part_class       text;
alter table qvm_new_apps.stock_auction_items    add column if not exists source_name_en   text;
alter table qvm_new_apps.stock_auction_items    add column if not exists clean_name_en    text;
alter table qvm_new_apps.stock_auction_items    add column if not exists brand            text;

-- ⑤ the thing several files add items to
create table if not exists qvm_new_apps.upload_campaigns (
  campaign_id bigint generated always as identity primary key,
  kind        text not null check (kind in ('offers', 'group_import', 'auction')),
  title       text not null,
  ends_on     date,
  source_kind text not null default 'internal' check (source_kind in ('vendor', 'agency', 'internal')),
  source_id   bigint,
  is_active   boolean not null default true,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index if not exists upload_campaigns_kind_idx on qvm_new_apps.upload_campaigns (kind, is_active);
alter table qvm_new_apps.upload_campaigns enable row level security;

alter table qvm_new_apps.part_offers            add column if not exists campaign_id bigint;
alter table qvm_new_apps.group_import_requests  add column if not exists campaign_id bigint;
alter table qvm_new_apps.stock_auction_items    add column if not exists campaign_id bigint;
create index if not exists part_offers_campaign_idx         on qvm_new_apps.part_offers (campaign_id);
create index if not exists group_import_campaign_idx        on qvm_new_apps.group_import_requests (campaign_id);
create index if not exists stock_auction_items_campaign_idx on qvm_new_apps.stock_auction_items (campaign_id);

-- ⑥ what the approximate name ladder needs
create extension if not exists pg_trgm with schema extensions;
create index if not exists part_name_dictionary_pn_trgm
  on qvm_new_apps.part_name_dictionary using gin (clean_part_number extensions.gin_trgm_ops);
