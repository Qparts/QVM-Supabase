-- The gate also enforces the party ceiling.
--
-- A limit nothing checks is a note in a settings screen. This is the only place that can stop a
-- call, so it is the only place the ceiling can mean anything.
--
-- Checked before the pool balance on purpose: «you have used your allowance» and «the company
-- has run out» are different problems with different people to go and see, and reporting the
-- second when the first is true sends the wrong person to fix it.
create or replace function qvm_new_apps.ai_can_run(
  p_company_id integer default null,
  p_vendor_id  integer default null)
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
  select o.company_id, o.vendor_id into v_co, v_vn
    from qvm_new_apps.ai_credit_owner_of(p_company_id, p_vendor_id) o;

  -- Nobody to bill. Qparts' own staff on the platform's account.
  if v_co is null and v_vn is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', true, 'reason', 'platform', 'balance', null, 'account_id', null));
  end if;

  select * into v_acct from qvm_new_apps.ai_credit_accounts a
   where a.company_id is not distinct from v_co and a.vendor_id is not distinct from v_vn;

  -- An organisation nobody has set up yet. Allowed: switching the AI off for every existing
  -- customer the moment this ships is not a feature, it is an outage.
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
     and s.party_company_id is not distinct from p_company_id
     and s.party_vendor_id  is not distinct from p_vendor_id;

  if v_pol.account_id is not null and not v_pol.is_enabled then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'party_disabled', 'account_id', v_acct.account_id,
      'balance', v_balance, 'note', v_pol.reason));
  end if;

  if v_pol.account_id is not null and v_pol.monthly_point_limit is not null then
    v_used := qvm_new_apps.ai_party_month_points(v_acct.account_id, p_company_id, p_vendor_id);
    if v_used >= v_pol.monthly_point_limit then
      return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
        'allowed', false, 'reason', 'party_limit', 'account_id', v_acct.account_id,
        'balance', v_balance,
        -- Both numbers, because «you are over your limit» without them is unanswerable.
        'limit', v_pol.monthly_point_limit, 'used', v_used));
    end if;
  end if;

  -- Refused at zero, not below it. The wallet is allowed to go negative because an AI charge is
  -- recorded after the provider has already been paid; this runs *before* the call, so there is
  -- nothing owed yet and no reason to let it start.
  if v_balance <= 0 then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'no_credit', 'account_id', v_acct.account_id,
      'balance', v_balance));
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'allowed', true, 'reason', 'ok', 'account_id', v_acct.account_id, 'balance', v_balance,
    'limit', v_pol.monthly_point_limit,
    'used', case when v_pol.monthly_point_limit is not null
                 then qvm_new_apps.ai_party_month_points(v_acct.account_id, p_company_id, p_vendor_id)
                 else null end,
    'low', v_acct.low_balance_threshold is not null and v_balance < v_acct.low_balance_threshold));
end
$$;
