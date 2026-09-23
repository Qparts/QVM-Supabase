-- The burn names the workshop the person belongs to.
--
-- `ai_usage_events` has no workshop column and is not going to grow one — it is written by a
-- client-side logger and the fewer things that logger has to be told, the fewer it can get wrong.
-- It does carry `auth_uid`, and `user_workshops` answers «which workshop is this person in», so
-- the trigger asks at the moment of the burn.
--
-- Resolved once, here, rather than at read time: a person can move between workshops, and a
-- charge belongs to where they were when they spent it, not where they are now. That is the same
-- reason the entry stores the party at all instead of deriving it from the user later.
create or replace function qvm_new_apps.wallet_charge_ai_usage()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_points numeric;
  v_ws     bigint;
  v_co     integer;
begin
  -- Nothing to bill.
  if coalesce(new.est_cost_usd, 0) <= 0 then return new; end if;

  -- Which workshop this person was in. Null for anyone who is not in one, which is everybody
  -- until somebody fills that table in.
  if new.auth_uid is not null then
    select uw.workshop_id into v_ws
      from qvm_new_apps.user_workshops uw
     where uw.user_id = new.auth_uid
     order by uw.workshop_id
     limit 1;
  end if;

  -- A workshop's points come out of its company's pool, even when the event itself never named
  -- a company — which is the usual case, since a workshop user has no user_company row.
  v_co := coalesce(new.company_id, case when v_ws is not null
                                        then qvm_new_apps.ai_workshop_company(v_ws) end);

  -- Nobody to bill it to. Qparts' own staff running the AI have no company, supplier or
  -- workshop, and that usage is the platform's.
  if v_co is null and new.vendor_id is null then return new; end if;

  v_points := qvm_new_apps.ai_points_for_usd(new.est_cost_usd);
  if v_points <= 0 then return new; end if;

  v_acct := qvm_new_apps.ai_credit_account_of(v_co, new.vendor_id, true);
  if v_acct is null then return new; end if;

  insert into qvm_new_apps.ai_credit_entries
    (account_id, points, kind, description,
     party_company_id, party_vendor_id, party_workshop_id, usage_event_id)
  values (v_acct, -v_points, 'usage', coalesce(new.action_type, 'AI'),
          -- Exactly one party. A workshop is the finer grain, so when there is one it is the
          -- party and the company is the pool — recording both would double the share column.
          case when v_ws is not null then null else new.company_id end,
          case when v_ws is not null then null else new.vendor_id end,
          v_ws,
          new.id)
  on conflict (usage_event_id) where usage_event_id is not null do nothing;

  perform qvm_new_apps.ai_credit_maybe_autotopup(v_acct);

  return new;
exception when others then
  raise warning 'ai credit: event % (account %, % points) was NOT charged: %',
    new.id, v_acct, v_points, sqlerrm;
  return new;
end
$$;

-- ── The gate learns the third kind ─────────────────────────────────────────────────────────────
drop function if exists qvm_new_apps.ai_can_run(integer, integer);

create or replace function qvm_new_apps.ai_can_run(
  p_company_id  integer default null,
  p_vendor_id   integer default null,
  p_workshop_id bigint  default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_co      integer;
  v_vn      integer;
  v_acct    record;
  v_balance numeric;
  v_pol     record;
  v_used    numeric;
begin
  -- A workshop draws on its company's pool.
  if p_workshop_id is not null then
    v_co := qvm_new_apps.ai_workshop_company(p_workshop_id);
    v_vn := null;
  else
    select o.company_id, o.vendor_id into v_co, v_vn
      from qvm_new_apps.ai_credit_owner_of(p_company_id, p_vendor_id) o;
  end if;

  if v_co is null and v_vn is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', true, 'reason', 'platform', 'balance', null, 'account_id', null));
  end if;

  select * into v_acct from qvm_new_apps.ai_credit_accounts a
   where a.company_id is not distinct from v_co and a.vendor_id is not distinct from v_vn;

  if v_acct.account_id is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', true, 'reason', 'no_account', 'balance', null, 'account_id', null));
  end if;

  v_balance := qvm_new_apps.ai_credit_balance(v_acct.account_id);

  if not v_acct.is_enabled then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'disabled', 'account_id', v_acct.account_id,
      'balance', v_balance, 'note', v_acct.disabled_reason));
  end if;

  select * into v_pol from qvm_new_apps.ai_credit_party_policy s
   where s.account_id = v_acct.account_id
     and s.party_company_id  is not distinct from p_company_id
     and s.party_vendor_id   is not distinct from p_vendor_id
     and s.party_workshop_id is not distinct from p_workshop_id;

  if v_pol.account_id is not null and not v_pol.is_enabled then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'party_disabled', 'account_id', v_acct.account_id,
      'balance', v_balance, 'note', v_pol.reason));
  end if;

  if v_pol.account_id is not null and v_pol.monthly_point_limit is not null then
    v_used := qvm_new_apps.ai_party_month_points(
                v_acct.account_id, p_company_id, p_vendor_id, p_workshop_id);
    if v_used >= v_pol.monthly_point_limit then
      return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
        'allowed', false, 'reason', 'party_limit', 'account_id', v_acct.account_id,
        'balance', v_balance, 'limit', v_pol.monthly_point_limit, 'used', v_used));
    end if;
  end if;

  if v_balance <= 0 then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'no_credit', 'account_id', v_acct.account_id,
      'balance', v_balance));
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'allowed', true, 'reason', 'ok', 'account_id', v_acct.account_id, 'balance', v_balance,
    'limit', v_pol.monthly_point_limit,
    'used', case when v_pol.monthly_point_limit is not null
                 then qvm_new_apps.ai_party_month_points(
                        v_acct.account_id, p_company_id, p_vendor_id, p_workshop_id)
                 else null end,
    'low', v_acct.low_balance_threshold is not null and v_balance < v_acct.low_balance_threshold));
end
$$;

-- The caller resolves their own workshop, for the same reason the trigger does.
create or replace function qvm_new_apps.ai_can_run_for_me()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_co integer;
  v_vn integer;
  v_ws bigint;
begin
  select ud.user_company, ud.user_vendor into v_co, v_vn
    from qvm_new_apps.user_data ud where ud.user_id = auth.uid() limit 1;

  select uw.workshop_id into v_ws
    from qvm_new_apps.user_workshops uw
   where uw.user_id = auth.uid() order by uw.workshop_id limit 1;

  -- A person in a workshop is gated as that workshop, not as the company behind it — otherwise
  -- a per-workshop limit is unenforceable for the only people it applies to.
  if v_ws is not null then
    return qvm_new_apps.ai_can_run(null, null, v_ws);
  end if;
  return qvm_new_apps.ai_can_run(v_co, v_vn, null);
end
$$;

grant execute on function qvm_new_apps.ai_can_run(integer, integer, bigint)
  to authenticated, service_role, anon;
grant execute on function qvm_new_apps.ai_can_run_for_me() to authenticated, service_role;
