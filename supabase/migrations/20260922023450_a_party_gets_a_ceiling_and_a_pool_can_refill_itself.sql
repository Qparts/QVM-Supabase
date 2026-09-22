-- A party gets a ceiling, and a pool can refill itself.
--
-- Two things the switch could not express. «Off» is the only answer a boolean has, and most of
-- the time the real intent is «yes, but not more than this» — a workshop that should be able to
-- read invoices without being able to burn the month's credit in an afternoon. And a pool that
-- can only be refilled by somebody noticing is a pool that stops the AI at 2am.

-- ── The ceiling ────────────────────────────────────────────────────────────────────────────────
-- The table is renamed with it. A thing called `party_switch` that also holds a monthly limit is
-- how the next reader ends up looking for the limits somewhere else.
alter table if exists qvm_new_apps.ai_credit_party_switch
  rename to ai_credit_party_policy;

alter table qvm_new_apps.ai_credit_party_policy
  -- Points per calendar month. Null is «no ceiling», which is not the same as 0 — 0 is a party
  -- that may not spend at all, and somebody will mean exactly that one day.
  add column if not exists monthly_point_limit numeric;

alter table qvm_new_apps.ai_credit_party_policy
  add constraint ai_credit_party_policy_limit_ck
  check (monthly_point_limit is null or monthly_point_limit >= 0);

comment on column qvm_new_apps.ai_credit_party_policy.monthly_point_limit is
  'Points this party may burn per calendar month. Null is uncapped; 0 is «none at all».';

-- What this party has burned this month, which is the number the ceiling is compared against.
create or replace function qvm_new_apps.ai_party_month_points(
  p_account_id bigint,
  p_company_id integer,
  p_vendor_id  integer)
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
     and c.party_company_id is not distinct from p_company_id
     and c.party_vendor_id  is not distinct from p_vendor_id
     and c.created_at >= date_trunc('month', current_date);
$$;

create or replace function qvm_new_apps.ai_credit_set_party(
  p_owner_company_id integer,
  p_owner_vendor_id  integer,
  p_party_company_id integer,
  p_party_vendor_id  integer,
  p_enabled          boolean,
  p_reason           text    default null,
  -- Passed explicitly so «leave the ceiling alone» and «remove the ceiling» are different calls.
  p_set_limit        boolean default false,
  p_monthly_limit    numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct     bigint;
  v_wallet   bigint;
  v_owner_co integer;
  v_owner_vn integer;
  v_reason   text := case when p_enabled then null else nullif(btrim(p_reason), '') end;
begin
  if (p_party_company_id is not null) = (p_party_vendor_id is not null) then
    return jsonb_build_object('status', false, 'message', 'حدد جهة واحدة', 'data', null);
  end if;
  if p_set_limit and p_monthly_limit is not null and p_monthly_limit < 0 then
    return jsonb_build_object('status', false, 'message', 'الحد لا يمكن أن يكون سالبًا', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_owner_company_id, p_owner_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;

  select o.company_id, o.vendor_id into v_owner_co, v_owner_vn
    from qvm_new_apps.ai_credit_owner_of(p_party_company_id, p_party_vendor_id) o;
  if v_owner_co is distinct from p_owner_company_id
     or v_owner_vn is distinct from p_owner_vendor_id then
    return jsonb_build_object('status', false, 'message', 'هذه الجهة لا تسحب من هذا الرصيد', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_owner_company_id, p_owner_vendor_id, true);

  -- One branch per partial index, because that is how many indexes there are.
  if p_party_company_id is not null then
    insert into qvm_new_apps.ai_credit_party_policy
      (account_id, party_company_id, party_vendor_id, is_enabled, reason, monthly_point_limit, set_by, set_at)
    values (v_acct, p_party_company_id, null, p_enabled, v_reason,
            case when p_set_limit then p_monthly_limit else null end, auth.uid(), now())
    on conflict (account_id, party_company_id) where party_company_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  monthly_point_limit = case when p_set_limit then excluded.monthly_point_limit
                                             else qvm_new_apps.ai_credit_party_policy.monthly_point_limit end,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  else
    insert into qvm_new_apps.ai_credit_party_policy
      (account_id, party_company_id, party_vendor_id, is_enabled, reason, monthly_point_limit, set_by, set_at)
    values (v_acct, null, p_party_vendor_id, p_enabled, v_reason,
            case when p_set_limit then p_monthly_limit else null end, auth.uid(), now())
    on conflict (account_id, party_vendor_id) where party_vendor_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  monthly_point_limit = case when p_set_limit then excluded.monthly_point_limit
                                             else qvm_new_apps.ai_credit_party_policy.monthly_point_limit end,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('account_id', v_acct, 'is_enabled', p_enabled));
end
$$;

-- ── Refilling itself ───────────────────────────────────────────────────────────────────────────
alter table qvm_new_apps.ai_credit_accounts
  add column if not exists auto_topup_enabled   boolean not null default false,
  -- Buy when the balance drops below this many points…
  add column if not exists auto_topup_threshold numeric,
  -- …and buy this many.
  add column if not exists auto_topup_points    numeric,
  add column if not exists auto_topup_last_at   timestamptz,
  -- When the wallet last refused. Without this, an empty wallet means a failed charge attempt on
  -- every single AI call for as long as it stays empty.
  add column if not exists auto_topup_failed_at timestamptz;

alter table qvm_new_apps.ai_credit_accounts
  add constraint ai_credit_accounts_auto_ck
  check (not auto_topup_enabled
         or (auto_topup_threshold is not null and auto_topup_threshold >= 0
             and auto_topup_points is not null and auto_topup_points > 0));

create or replace function qvm_new_apps.ai_credit_set_auto_topup(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_enabled    boolean default false,
  p_threshold  numeric default null,
  p_points     numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_wallet bigint;
begin
  v_wallet := qvm_new_apps.wallet_of(p_company_id, p_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;
  if p_enabled and (coalesce(p_threshold, -1) < 0 or coalesce(p_points, 0) <= 0) then
    return jsonb_build_object('status', false, 'message', 'حدد حد التنبيه وعدد النقاط', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_company_id, p_vendor_id, true);
  update qvm_new_apps.ai_credit_accounts
     set auto_topup_enabled   = p_enabled,
         auto_topup_threshold = case when p_enabled then p_threshold else null end,
         auto_topup_points    = case when p_enabled then p_points    else null end,
         -- Turning it on clears the last failure: the person doing it has presumably dealt with
         -- whatever the wallet was short of, and should not wait out an hour they cannot see.
         auto_topup_failed_at = null,
         updated_at = now()
   where account_id = v_acct;

  return jsonb_build_object('status', true, 'message', 'ok', 'data',
    jsonb_build_object('account_id', v_acct, 'enabled', p_enabled));
end
$$;

grant execute on function qvm_new_apps.ai_party_month_points(bigint, integer, integer) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_set_party(integer, integer, integer, integer, boolean, text, boolean, numeric) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_set_auto_topup(integer, integer, boolean, numeric, numeric) to authenticated, service_role;
