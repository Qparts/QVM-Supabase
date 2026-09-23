-- A workshop is a party too, not just a row in somebody else's tree.
--
-- The credit page listed the organisation and its suppliers. A company's workshops — the things
-- the Companies & Workshops page is mostly made of — were invisible, so there was no way to cap
-- one or switch it off, and no way to see which of them was burning the month's points.
--
-- Earlier this was written off as unmeterable, on the grounds that `ai_usage_events` carries only
-- a company and a vendor. That was half right: the *event* carries no workshop, but it carries
-- `auth_uid`, and `user_workshops` says which workshop a person belongs to. So the attribution
-- exists; nobody had followed it.
--
-- What is genuinely missing is the data. `user_workshops` is empty — six workshops, ten links to
-- companies, and not one person attached to any of them. So these rows will read zero until
-- somebody assigns users, and a permanent zero that looks like «this workshop does not use AI» is
-- a lie. The overview flags a workshop with nobody in it, so the zero is explained rather than
-- merely displayed.

-- ── The ledger learns a third kind of party ────────────────────────────────────────────────────
alter table qvm_new_apps.ai_credit_entries
  add column if not exists party_workshop_id bigint;

alter table qvm_new_apps.ai_credit_party_policy
  add column if not exists party_workshop_id bigint;

-- The policy table's «exactly one kind» rule has to admit the third.
alter table qvm_new_apps.ai_credit_party_policy
  drop constraint if exists ai_credit_party_switch_party_ck;
alter table qvm_new_apps.ai_credit_party_policy
  drop constraint if exists ai_credit_party_policy_party_ck;
alter table qvm_new_apps.ai_credit_party_policy
  add constraint ai_credit_party_policy_party_ck
  check ((party_company_id is not null)::int
       + (party_vendor_id  is not null)::int
       + (party_workshop_id is not null)::int = 1);

-- One partial index per kind, because the unused columns are null and NULL never collides.
create unique index if not exists ai_credit_party_policy_ws_uq
  on qvm_new_apps.ai_credit_party_policy (account_id, party_workshop_id)
  where party_workshop_id is not null;

create index if not exists ai_credit_entries_ws_idx
  on qvm_new_apps.ai_credit_entries (account_id, party_workshop_id)
  where party_workshop_id is not null;

-- ── Whose pool a workshop draws on ─────────────────────────────────────────────────────────────
-- Its company's, the same link the rest of the platform uses. `is_primary` decides when a
-- workshop serves more than one — a workshop that works for three companies still has one that
-- pays for it.
create or replace function qvm_new_apps.ai_workshop_company(p_workshop_id bigint)
returns integer
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select wc.company_id
    from qvm_new_apps.workshop_companies wc
   where wc.workshop_id = p_workshop_id
   order by wc.is_primary desc nulls last, wc.company_id
   limit 1;
$$;

-- What a party has burned this month. The signature gains a workshop, so the old one is dropped
-- rather than left beside it — `create or replace` with a different argument list makes a second
-- function, and the callers would keep reaching the stale one.
drop function if exists qvm_new_apps.ai_party_month_points(bigint, integer, integer);

create or replace function qvm_new_apps.ai_party_month_points(
  p_account_id  bigint,
  p_company_id  integer,
  p_vendor_id   integer,
  p_workshop_id bigint default null)
returns numeric
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select coalesce(-sum(c.points), 0)
    from qvm_new_apps.ai_credit_entries c
   where c.account_id = p_account_id
     and c.kind = 'usage'
     and c.party_company_id  is not distinct from p_company_id
     and c.party_vendor_id   is not distinct from p_vendor_id
     and c.party_workshop_id is not distinct from p_workshop_id
     and c.created_at >= date_trunc('month', current_date);
$$;

grant execute on function qvm_new_apps.ai_workshop_company(bigint) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_party_month_points(bigint, integer, integer, bigint)
  to authenticated, service_role;
