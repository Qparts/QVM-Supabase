-- AI credit: one pool per organisation, and a switch per party.
--
-- Today AI usage is charged straight to the wallet in SAR, which makes «the AI stopped» and «the
-- platform stopped» the same event: run the wallet down and subscriptions fail too, and keep the
-- wallet healthy for subscriptions and the AI is silently uncapped. An organisation that wants to
-- cap what it spends on the model has no way to say so.
--
-- So AI gets its own pool. Money still enters through the wallet — there is one door for that —
-- and buying credit moves SAR out of the wallet and into this pool. Denominated in SAR, not in
-- invented «credits»: a second unit needs an exchange rate, and an exchange rate needs somebody
-- to maintain it.
--
-- The pool sits at the organisation and the parties under it draw from it. That is what the
-- design's «share of total» column means, and it is also the only arrangement in which a company
-- can switch off one workshop's AI without touching anybody else's.

-- ── The pool ───────────────────────────────────────────────────────────────────────────────────
create table if not exists qvm_new_apps.ai_credit_accounts (
  account_id  bigserial primary key,
  -- Keyed exactly like `wallets`: a pool belongs to a company or to a supplier, never both and
  -- never neither. Using a different shape here would mean two ways to say «whose», and one of
  -- them would eventually be resolved wrongly.
  company_id  integer references qvm_new_apps.client_companies(company_id) on delete cascade,
  vendor_id   integer references qvm_new_apps.vendors(vendor_id) on delete cascade,

  -- The master switch. Off means no AI for this organisation at all, whatever the balance.
  is_enabled  boolean     not null default true,
  disabled_reason text,
  disabled_by uuid,
  disabled_at timestamptz,

  -- Warn here rather than at zero, since «the AI stopped mid-upload» is a bad way to find out.
  low_balance_threshold numeric,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint ai_credit_accounts_owner_ck
    check ((company_id is not null) <> (vendor_id is not null))
);

create unique index if not exists ai_credit_accounts_company_uq
  on qvm_new_apps.ai_credit_accounts (company_id) where company_id is not null;
create unique index if not exists ai_credit_accounts_vendor_uq
  on qvm_new_apps.ai_credit_accounts (vendor_id) where vendor_id is not null;

alter table qvm_new_apps.ai_credit_accounts enable row level security;

-- ── The ledger ─────────────────────────────────────────────────────────────────────────────────
create table if not exists qvm_new_apps.ai_credit_entries (
  entry_id    bigserial primary key,
  account_id  bigint      not null references qvm_new_apps.ai_credit_accounts(account_id) on delete cascade,
  -- Positive buys credit, negative spends it. One signed column rather than two, so the balance
  -- is a sum and cannot disagree with itself.
  amount      numeric     not null,
  kind        text        not null,
  description text,

  -- Which party spent it. Null on a top-up: nobody consumed that.
  party_company_id integer,
  party_vendor_id  integer,

  -- The AI event this entry pays for. Unique, so one call can never be billed twice — the
  -- structural guarantee, not a promise that the trigger only fires once.
  usage_event_id bigint,
  -- The SAR that bought this credit, for a top-up.
  wallet_entry_id bigint references qvm_new_apps.wallet_entries(entry_id),

  created_by  uuid,
  created_at  timestamptz not null default now(),

  constraint ai_credit_entries_kind_ck
    check (kind in ('topup', 'usage', 'adjustment', 'refund')),
  constraint ai_credit_entries_amount_ck check (amount <> 0)
);

create unique index if not exists ai_credit_entries_event_uq
  on qvm_new_apps.ai_credit_entries (usage_event_id) where usage_event_id is not null;
create index if not exists ai_credit_entries_account_idx
  on qvm_new_apps.ai_credit_entries (account_id, created_at desc);
create index if not exists ai_credit_entries_party_idx
  on qvm_new_apps.ai_credit_entries (account_id, party_company_id, party_vendor_id);

alter table qvm_new_apps.ai_credit_entries enable row level security;

comment on table qvm_new_apps.ai_credit_entries is
  'Append-only. Balance is the sum, never a stored figure — unlike wallet_entries, which carries '
  'balance_after because a person reads it line by line. Nobody reads this one that way.';

create or replace function qvm_new_apps.ai_credit_entries_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'ai_credit_entries is append-only (attempted %)', tg_op;
end
$$;

drop trigger if exists ai_credit_entries_no_change on qvm_new_apps.ai_credit_entries;
create trigger ai_credit_entries_no_change
  before update or delete on qvm_new_apps.ai_credit_entries
  for each row execute function qvm_new_apps.ai_credit_entries_append_only();

-- ── The per-party switch ───────────────────────────────────────────────────────────────────────
-- Absent means allowed. Storing a row per party up front would mean inventing rows for parties
-- that have never used the AI, and then keeping them in step with a tree that changes.
create table if not exists qvm_new_apps.ai_credit_party_switch (
  account_id  bigint  not null references qvm_new_apps.ai_credit_accounts(account_id) on delete cascade,
  party_company_id integer,
  party_vendor_id  integer,
  is_enabled  boolean not null default true,
  reason      text,
  set_by      uuid,
  set_at      timestamptz not null default now(),
  constraint ai_credit_party_switch_party_ck
    check ((party_company_id is not null) <> (party_vendor_id is not null))
);

create unique index if not exists ai_credit_party_switch_co_uq
  on qvm_new_apps.ai_credit_party_switch (account_id, party_company_id) where party_company_id is not null;
create unique index if not exists ai_credit_party_switch_vn_uq
  on qvm_new_apps.ai_credit_party_switch (account_id, party_vendor_id) where party_vendor_id is not null;

alter table qvm_new_apps.ai_credit_party_switch enable row level security;

-- ── Whose pool pays for this party ─────────────────────────────────────────────────────────────
-- A supplier linked to a company spends that company's credit; the link table is the same one
-- the rest of the platform already uses to say who a supplier works for. A supplier linked to
-- nobody is its own organisation and holds its own pool.
--
-- Returns the *owner*, not the account — the account may not exist yet, and deciding who pays is
-- a different question from having somewhere to record it.
create or replace function qvm_new_apps.ai_credit_owner_of(
  p_company_id integer,
  p_vendor_id  integer)
returns table (company_id integer, vendor_id integer)
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select
    case
      when p_company_id is not null then p_company_id
      when p_vendor_id is not null then (
        select vc.company_id from qvm_new_apps.vendor_companies vc
         where vc.vendor_id = p_vendor_id
         order by vc.company_id
         limit 1)
      else null
    end as company_id,
    case
      when p_company_id is not null then null
      when p_vendor_id is not null and not exists (
             select 1 from qvm_new_apps.vendor_companies vc where vc.vendor_id = p_vendor_id)
        then p_vendor_id
      else null
    end as vendor_id;
$$;

-- Find or create the pool. Creating on demand keeps every organisation's first AI call from
-- needing somebody to have set it up first.
create or replace function qvm_new_apps.ai_credit_account_of(
  p_company_id integer,
  p_vendor_id  integer,
  p_create     boolean default false)
returns bigint
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_co integer;
  v_vn integer;
  v_id bigint;
begin
  select o.company_id, o.vendor_id into v_co, v_vn
    from qvm_new_apps.ai_credit_owner_of(p_company_id, p_vendor_id) o;
  if v_co is null and v_vn is null then return null; end if;

  select a.account_id into v_id from qvm_new_apps.ai_credit_accounts a
   where a.company_id is not distinct from v_co and a.vendor_id is not distinct from v_vn;
  if v_id is not null or not p_create then return v_id; end if;

  insert into qvm_new_apps.ai_credit_accounts (company_id, vendor_id)
  values (v_co, v_vn)
  on conflict do nothing
  returning account_id into v_id;

  -- Lost the race to a concurrent creator; theirs is just as good.
  if v_id is null then
    select a.account_id into v_id from qvm_new_apps.ai_credit_accounts a
     where a.company_id is not distinct from v_co and a.vendor_id is not distinct from v_vn;
  end if;
  return v_id;
end
$$;

create or replace function qvm_new_apps.ai_credit_balance(p_account_id bigint)
returns numeric
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select coalesce(sum(amount), 0) from qvm_new_apps.ai_credit_entries
   where account_id = p_account_id;
$$;

grant execute on function qvm_new_apps.ai_credit_owner_of(integer, integer) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_account_of(integer, integer, boolean) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_balance(bigint) to authenticated, service_role;
