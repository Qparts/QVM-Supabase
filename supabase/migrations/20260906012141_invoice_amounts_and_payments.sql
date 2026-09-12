-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-6 / S-7 — the finance half of the order.
--
-- `invoices` held a Zoho number, a URL and a status, and no money at all: the amount of every
-- invoice in this system lived in Zoho, so «what does this customer owe» was a screenshot.
-- The columns arrive here to be synced from Zoho (Open Decision 5, recommended), with the
-- line-item computation as the fallback the ticket names so the page is not blank until that
-- sync exists.
alter table qvm_new_apps.invoices
  add column if not exists subtotal    numeric,
  add column if not exists vat         numeric,
  add column if not exists total       numeric,
  add column if not exists paid_amount numeric not null default 0,
  add column if not exists currency    text not null default 'SAR',
  -- Where the figures came from, so a synced total and a computed one are never mistaken for
  -- each other. A computed total is an estimate until Zoho confirms it.
  add column if not exists amounts_source text not null default 'computed'
    check (amounts_source in ('zoho', 'computed', 'manual'));

-- Balance is derived, never stored: a stored balance and its inputs disagree the first time
-- somebody edits one of them.
create or replace view qvm_new_apps.invoice_balances as
  select i.invoice_id,
         coalesce(i.total, 0) - coalesce(i.paid_amount, 0) as balance
    from qvm_new_apps.invoices i;

-- S-7 — payments, and what each one settles.
--
-- Split in two because one payment routinely covers several invoices and one invoice is
-- routinely settled by several payments. Folding that into a column on either side is how a
-- statement stops adding up.
create table if not exists qvm_new_apps.payments (
  payment_id   bigint generated always as identity primary key,
  customer_id  bigint references qvm_new_apps.customers(customer_id),
  -- The client company as the rest of this system knows it (list 1), kept because most orders
  -- still resolve to a company and not yet to a customers row.
  company_list_data_id integer,
  paid_on      date not null default current_date,
  amount       numeric not null check (amount > 0),
  method       text,
  reference    text,
  zoho_payment_id text unique,
  notes        text,
  -- 'zoho' when it arrived from the sync, 'manual' when somebody entered a cash or transfer
  -- receipt. The two are never merged: one is evidence, the other is a claim.
  source       text not null default 'manual' check (source in ('zoho', 'manual')),
  created_by   uuid,
  created_at   timestamptz not null default now()
);

create index if not exists payments_customer_idx on qvm_new_apps.payments(customer_id);
create index if not exists payments_company_idx  on qvm_new_apps.payments(company_list_data_id);
create index if not exists payments_date_idx     on qvm_new_apps.payments(paid_on);

create table if not exists qvm_new_apps.payment_allocations (
  allocation_id bigint generated always as identity primary key,
  payment_id    bigint not null references qvm_new_apps.payments(payment_id) on delete cascade,
  invoice_id    bigint not null references qvm_new_apps.invoices(invoice_id) on delete restrict,
  amount        numeric not null check (amount > 0),
  created_at    timestamptz not null default now(),
  unique (payment_id, invoice_id)
);

create index if not exists payment_allocations_invoice_idx on qvm_new_apps.payment_allocations(invoice_id);

alter table qvm_new_apps.payments            enable row level security;
alter table qvm_new_apps.payment_allocations enable row level security;

-- An invoice's paid amount is the sum of what has been allocated to it. Kept as a column
-- because the invoice list sorts and filters on it, and refreshed from the allocations rather
-- than typed, so the two cannot drift.
create or replace function qvm_new_apps.invoice_refresh_paid(p_invoice_id bigint)
returns void
language sql
security definer
set search_path to 'qvm_new_apps', 'public'
as $fn$
  update qvm_new_apps.invoices i
     set paid_amount = coalesce((
           select sum(a.amount) from qvm_new_apps.payment_allocations a
            where a.invoice_id = p_invoice_id), 0),
         paid_at = case
           when coalesce((select sum(a.amount) from qvm_new_apps.payment_allocations a
                           where a.invoice_id = p_invoice_id), 0) >= coalesce(i.total, 0)
                and coalesce(i.total, 0) > 0
           then coalesce(i.paid_at, now())
           else null end
   where i.invoice_id = p_invoice_id;
$fn$;
