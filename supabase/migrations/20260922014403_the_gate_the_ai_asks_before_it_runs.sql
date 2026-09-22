-- The gate the AI asks before it runs.
--
-- «If the credit is gone the AI must stop everywhere» is only true if there is one place every
-- model call passes through. There is: the `ai-ocr` Edge Function holds the key, and the comment
-- at the top of geminiInvoiceOcr.ts already tells anyone adding a second model call to put it
-- behind the same function. So this is what that function asks, before it reaches for the key.
--
-- The front end asks it too, to grey a button and say why — but that is courtesy. A check that
-- only runs in the browser is a suggestion.
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
  v_switch  record;
begin
  select o.company_id, o.vendor_id into v_co, v_vn
    from qvm_new_apps.ai_credit_owner_of(p_company_id, p_vendor_id) o;

  -- Nobody to bill. This is Qparts' own staff using the AI on the platform's account, which is
  -- most of the traffic today and is not something an organisation's balance should gate.
  -- Allowed, and said plainly rather than by falling through a hole.
  if v_co is null and v_vn is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', true, 'reason', 'platform', 'balance', null, 'account_id', null));
  end if;

  select * into v_acct from qvm_new_apps.ai_credit_accounts a
   where a.company_id is not distinct from v_co and a.vendor_id is not distinct from v_vn;

  -- An organisation nobody has set up yet. Allowed: switching the AI off for every existing
  -- customer the moment this ships is not a feature, it is an outage. They appear with a zero
  -- balance and an open pool, and stop when somebody decides they should.
  if v_acct.account_id is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', true, 'reason', 'no_account', 'balance', null, 'account_id', null));
  end if;

  if not v_acct.is_enabled then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'disabled', 'account_id', v_acct.account_id,
      'balance', qvm_new_apps.ai_credit_balance(v_acct.account_id),
      'note', v_acct.disabled_reason));
  end if;

  -- The party's own switch, which is how a company turns off one workshop without touching the
  -- rest. Absent means allowed — see the table comment.
  select * into v_switch from qvm_new_apps.ai_credit_party_switch s
   where s.account_id = v_acct.account_id
     and s.party_company_id is not distinct from p_company_id
     and s.party_vendor_id  is not distinct from p_vendor_id;

  if v_switch.account_id is not null and not v_switch.is_enabled then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'allowed', false, 'reason', 'party_disabled', 'account_id', v_acct.account_id,
      'balance', qvm_new_apps.ai_credit_balance(v_acct.account_id),
      'note', v_switch.reason));
  end if;

  v_balance := qvm_new_apps.ai_credit_balance(v_acct.account_id);

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
    'low', v_acct.low_balance_threshold is not null and v_balance < v_acct.low_balance_threshold));
end
$$;

-- The caller the Edge Function is: it has a JWT but resolving «which company» from it is the
-- database's job, not something a function should be told by its own request body.
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
begin
  select ud.user_company, ud.user_vendor into v_co, v_vn
    from qvm_new_apps.user_data ud
   where ud.user_id = auth.uid()
   limit 1;
  return qvm_new_apps.ai_can_run(v_co, v_vn);
end
$$;

grant execute on function qvm_new_apps.ai_can_run(integer, integer) to authenticated, service_role, anon;
grant execute on function qvm_new_apps.ai_can_run_for_me() to authenticated, service_role;
