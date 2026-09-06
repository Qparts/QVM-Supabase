-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-123 — the customers module.
--
-- A customer today is a dropdown row: a name in list_data list 1, with branches
-- in client_branches. There is no CR number, no payment terms, no address and no
-- documents. This adds the master beside list 1 rather than promoting list 1
-- into it, so quotations, user_data, order_number_sequences and every report
-- keep the keys they already use — nothing is re-keyed and nothing breaks.
--
-- Verified against the live database before writing: 13 companies in list 1, but
-- only 3 branches and all of them under one company. So linking "every existing
-- company" on first deploy produces 12 customers with no branch — which is why
-- `needs_review` exists and is set for them.

-- --- the master -------------------------------------------------------------
create table if not exists qvm_new_apps.customers (
  customer_id        bigserial primary key,
  -- The existing company row stays the key everything else joins on.
  list_data_id       integer not null unique
                     references qvm_new_apps.list_data(list_data_id),
  source             text not null default 'manual'
                     check (source in ('database','manual','auto')),
  name_ar            text,
  name_en            text,
  customer_type      text check (customer_type in ('workshop','insurance','other')),
  cr_number          text,
  vat_number         text,
  contact_person     text,
  phone              text,
  email              text,
  region_id          integer,
  -- Payment terms (C-4). Enforcement is warning-only in v1: invoices carry no
  -- amounts yet, so nothing can be computed until QNEW-124 adds them.
  payment_terms_days integer check (payment_terms_days is null or payment_terms_days >= 0),
  credit_limit       numeric(14,2) check (credit_limit is null or credit_limit >= 0),
  credit_hold        boolean not null default false,
  payment_method_note text,
  -- C-7: off by default, so nothing changes for a customer nobody switches on.
  approvals_enabled  boolean not null default false,
  is_active          boolean not null default true,
  -- An `auto` record, or a `database` one with no branch, is incomplete until an
  -- admin finishes or merges it.
  needs_review       boolean not null default false,
  merged_into        bigint references qvm_new_apps.customers(customer_id),
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Duplicate detection (C-2): only among live records, and only where the number
-- is actually filled in.
create unique index if not exists customers_cr_unique
  on qvm_new_apps.customers (lower(btrim(cr_number)))
  where cr_number is not null and btrim(cr_number) <> '' and merged_into is null;
create unique index if not exists customers_vat_unique
  on qvm_new_apps.customers (lower(btrim(vat_number)))
  where vat_number is not null and btrim(vat_number) <> '' and merged_into is null;
create index if not exists customers_source_idx on qvm_new_apps.customers (source, is_active);

-- --- addresses (C-5) --------------------------------------------------------
create table if not exists qvm_new_apps.customer_addresses (
  address_id       bigserial primary key,
  customer_id      bigint not null references qvm_new_apps.customers(customer_id) on delete cascade,
  -- client_branches.customer_id is the BRANCH id despite the name.
  client_branch_id bigint references qvm_new_apps.client_branches(customer_id) on delete cascade,
  label            text,
  address_line     text,
  city             text,
  region_id        integer,
  geo_lat          numeric(10,7),
  geo_lng          numeric(10,7),
  contact_name     text,
  contact_phone    text,
  -- The create-order page offers only receives_orders; the shipping board only
  -- receives_shipments.
  receives_orders    boolean not null default true,
  receives_shipments boolean not null default true,
  is_default       boolean not null default false,
  is_active        boolean not null default true,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- One default per branch, counting only live addresses.
create unique index if not exists customer_addresses_one_default_per_branch
  on qvm_new_apps.customer_addresses (client_branch_id)
  where is_default and is_active;
create index if not exists customer_addresses_customer_idx
  on qvm_new_apps.customer_addresses (customer_id, is_active);

-- --- approvers and their branches (C-7) -------------------------------------
--
-- user_data.user_branch holds ONE branch. This does not replace it: a user with
-- no rows here keeps user_branch as their only branch, so customers that never
-- enable approvals see no change at all.
create table if not exists qvm_new_apps.user_branches (
  user_id          uuid not null references auth.users(id) on delete cascade,
  client_branch_id bigint not null references qvm_new_apps.client_branches(customer_id) on delete cascade,
  is_approver      boolean not null default false,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  primary key (user_id, client_branch_id)
);
create index if not exists user_branches_branch_idx on qvm_new_apps.user_branches (client_branch_id);

-- --- audit (D) --------------------------------------------------------------
create table if not exists qvm_new_apps.customer_log (
  log_id      bigserial primary key,
  customer_id bigint references qvm_new_apps.customers(customer_id) on delete cascade,
  entity      text not null check (entity in ('customer','address','document','approver','terms')),
  entity_id   bigint,
  action      text not null check (action in ('create','update','delete','merge')),
  before      jsonb,
  after       jsonb,
  changed_by  uuid references auth.users(id),
  changed_at  timestamptz not null default now()
);
create index if not exists customer_log_customer_idx on qvm_new_apps.customer_log (customer_id, changed_at desc);

-- --- official documents (C-6) -----------------------------------------------
--
-- The ticket puts these on `files` with module_type = 'customer'. `files` has no
-- type, number or expiry column, and the acceptance criteria need all three
-- («منتهي» / «ينتهي خلال 30 يوم»). Adding them here as nullable keeps the
-- ticket's storage decision and cannot affect the other modules that write to
-- this table — every existing insert stays valid.
alter table qvm_new_apps.files add column if not exists doc_type   text;
alter table qvm_new_apps.files add column if not exists doc_number text;
alter table qvm_new_apps.files add column if not exists issued_on  date;
alter table qvm_new_apps.files add column if not exists expires_on date;

create index if not exists files_customer_docs_idx
  on qvm_new_apps.files (module_id, doc_type)
  where module_type = 'customer';

-- --- the order carries its kind and address (C-8, C-9) ----------------------
alter table qvm_new_apps.quotations add column if not exists request_kind text
  check (request_kind is null or request_kind in ('quote','purchase'));
alter table qvm_new_apps.quotations add column if not exists customer_address_id bigint
  references qvm_new_apps.customer_addresses(address_id);

-- Reachable only through SECURITY DEFINER RPCs, exactly like the WhatsApp
-- tables — identity comes from auth.uid() inside the function, never from a
-- parameter the caller supplies.
alter table qvm_new_apps.customers          enable row level security;
alter table qvm_new_apps.customer_addresses enable row level security;
alter table qvm_new_apps.user_branches      enable row level security;
alter table qvm_new_apps.customer_log       enable row level security;
