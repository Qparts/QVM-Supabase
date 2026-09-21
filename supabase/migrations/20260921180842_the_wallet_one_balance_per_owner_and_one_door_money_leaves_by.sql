-- The wallet: one balance per company or vendor, and one door money leaves by.
--
-- Everything the platform will charge for — integration subscriptions, AI credit, per-use
-- consumption — has to come out of somewhere the owner can see and top up. Today the AI spend is
-- logged and nobody is billed for it, and the integrations that will need paying for do not exist
-- yet. This is the account they all draw on, built before them so they have somewhere to draw
-- from rather than each inventing its own.
--
-- ── Who owns one ───────────────────────────────────────────────────────────────────────────────
-- A company or a vendor, never both, exactly one. Two nullable foreign keys with a check rather
-- than the usual (owner_kind, owner_id) pair: the pair cannot be a foreign key, so it lets a
-- wallet point at a company that was deleted, and money is the last place to give up referential
-- integrity for tidiness.
create table if not exists qvm_new_apps.wallets (
  wallet_id   bigserial primary key,
  company_id  integer references qvm_new_apps.client_companies(company_id) on delete restrict,
  vendor_id   integer references qvm_new_apps.vendors(vendor_id) on delete restrict,
  currency    text not null default 'SAR',
  -- «تنبيه انخفاض الرصيد عند أقل من …». Null means nobody asked to be warned.
  low_balance_threshold numeric,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint wallets_one_owner check (num_nonnulls(company_id, vendor_id) = 1)
);

-- One wallet per owner. Two wallets for one company is two answers to «what is our balance».
create unique index if not exists wallets_company_uniq on qvm_new_apps.wallets (company_id)
  where company_id is not null;
create unique index if not exists wallets_vendor_uniq on qvm_new_apps.wallets (vendor_id)
  where vendor_id is not null;

alter table qvm_new_apps.wallets enable row level security;

-- ── The ledger ─────────────────────────────────────────────────────────────────────────────────
-- Append-only. No updates, no deletes — a correction is another entry, which is why `adjustment`
-- exists as a kind. That is not ceremony: a ledger you can edit cannot be reconciled against a
-- bank statement, and the first time someone quietly fixes a row the balance stops being evidence.
--
-- `amount` is signed. Positive adds, negative spends. One column rather than debit/credit because
-- every sum in this module is «how much did the balance move», and splitting it into two columns
-- means every reader has to remember which way round they go.
--
-- `balance_after` is stored, and that is a deliberate exception to deriving everything. It is
-- correct here for a reason that does not apply elsewhere: entries are immutable and every write
-- goes through wallet_charge, which takes a lock on the wallet row first. So the number is a fact
-- at the moment of insert, not a cache that can drift behind its source. wallet_verify() re-derives
-- the whole chain and reports any disagreement, so if that assumption is ever broken it is found
-- rather than believed.
create table if not exists qvm_new_apps.wallet_entries (
  entry_id      bigserial primary key,
  wallet_id     bigint not null references qvm_new_apps.wallets(wallet_id) on delete restrict,
  amount        numeric not null check (amount <> 0),
  balance_after numeric not null,
  kind          text not null check (kind in
                  ('topup','consumption','subscription','operational','refund','adjustment')),
  -- Where it came from, so a line can be traced to the thing that caused it rather than just
  -- described. 'ai' / 'integration' / 'manual' …
  source        text,
  source_id     text,
  reference     text,
  description   text,
  -- «تاريخ الانتهاء» — a subscription line covers a period; a consumption line does not.
  expires_on    date,
  invoice_url   text,
  created_at    timestamptz not null default now(),
  created_by    uuid
);

create index if not exists wallet_entries_wallet_idx
  on qvm_new_apps.wallet_entries (wallet_id, entry_id desc);
create index if not exists wallet_entries_source_idx
  on qvm_new_apps.wallet_entries (source, source_id);

alter table qvm_new_apps.wallet_entries enable row level security;

comment on table qvm_new_apps.wallet_entries is
  'Append-only. Corrections are new entries of kind ''adjustment'', never edits — a ledger that '
  'can be edited cannot be reconciled against a bank statement.';

-- ── Subscriptions ──────────────────────────────────────────────────────────────────────────────
-- The integrations marketplace does not exist yet. This is what it will write to, modelled now so
-- that when it arrives it charges the same wallet through the same door instead of growing its
-- own billing.
create table if not exists qvm_new_apps.wallet_subscriptions (
  subscription_id bigserial primary key,
  wallet_id     bigint not null references qvm_new_apps.wallets(wallet_id) on delete restrict,
  -- 'mrsool' | 'whatsapp' | 'email' | 'part_number' | 'ai' | 'smsa' … free text on purpose: the
  -- marketplace is not built, and a check constraint written before the list is known would have
  -- to be migrated the first time somebody adds a service.
  service_key   text not null,
  plan_name     text,
  amount        numeric not null check (amount >= 0),
  period        text not null check (period in ('monthly','yearly')),
  status        text not null default 'active' check (status in ('active','cancelled')),
  started_on    date not null default current_date,
  -- The day the next charge is due. Also the «تاريخ الانتهاء» shown against the last charge.
  renews_on     date not null,
  cancelled_at  timestamptz,
  cancelled_by  uuid,
  created_at    timestamptz not null default now(),
  created_by    uuid
);

create unique index if not exists wallet_subscriptions_active_uniq
  on qvm_new_apps.wallet_subscriptions (wallet_id, service_key)
  where status = 'active';

alter table qvm_new_apps.wallet_subscriptions enable row level security;

-- ── The price list ─────────────────────────────────────────────────────────────────────────────
-- What a unit of something costs the owner. Kept as data rather than baked into the charging code
-- so a price change is a row, not a migration — and so the number that was charged last month can
-- still be read next year.
create table if not exists qvm_new_apps.wallet_rates (
  rate_key    text primary key,
  amount      numeric not null,
  unit        text not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

alter table qvm_new_apps.wallet_rates enable row level security;

-- The AI is billed on what it actually cost us, marked up by nothing for now, converted at the
-- peg. Both numbers are rows so neither is buried in a function: 'ai_usd_to_sar' is the currency
-- peg, 'ai_markup' is the multiplier, and setting the markup to 1 means «bill at cost», which is
-- what this starts at.
insert into qvm_new_apps.wallet_rates (rate_key, amount, unit, description) values
  ('ai_usd_to_sar', 3.75, 'SAR per USD', 'Riyal peg used to bill AI usage logged in USD'),
  ('ai_markup',     1.00, 'multiplier',  'Applied to the AI cost before it is charged. 1 = at cost')
on conflict (rate_key) do nothing;
