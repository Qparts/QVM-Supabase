-- Who may read a wallet, and who may move its money.
--
-- Reading and managing are the same set here, deliberately: a balance is not a secret from the
-- people who spend it, and there is nobody in this system who should see the balance but not be
-- able to top it up. If that changes, this is the one place it splits.
--
-- Qparts operations reaches any wallet — they are the ones who take the money and record it. An
-- owner reaches their own. Nobody reaches anyone else's.
create or replace function qvm_new_apps.wallet_can_manage(p_wallet_id bigint)
returns boolean
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select case
    when p_wallet_id is null then false
    when qvm_new_apps.is_qparts_team() then true
    else exists (
      select 1 from qvm_new_apps.wallets w
       where w.wallet_id = p_wallet_id
         and (
           (w.company_id is not null and exists (
              select 1 from qvm_new_apps.user_companies uc
               where uc.user_id = auth.uid() and uc.company_id = w.company_id))
           or (w.vendor_id is not null
               and w.vendor_id = qvm_new_apps.current_upload_vendor_id())))
  end;
$$;

-- ── The page's read ────────────────────────────────────────────────────────────────────────────
-- Balance, the ledger, the subscriptions and whether the low-balance warning is tripped, in one
-- call. The balance is summed from the entries rather than read off the last row's balance_after:
-- they agree by construction, and summing is the definition while the stored column is the
-- convenience.
create or replace function qvm_new_apps.wallet_get(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_limit      integer default 50,
  p_offset     integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_wallet bigint;
  v_co     integer := p_company_id;
  v_ve     integer := p_vendor_id;
  v_row    record;
  v_entries jsonb; v_total bigint; v_subs jsonb; v_balance numeric;
begin
  -- An owner never picks whose wallet to open; they get their own whatever they asked for.
  if not v_team then
    v_ve := qvm_new_apps.current_upload_vendor_id();
    if v_ve is null then
      select uc.company_id into v_co from qvm_new_apps.user_companies uc
       where uc.user_id = auth.uid() limit 1;
      v_ve := null;
    else
      v_co := null;
    end if;
    if v_co is null and v_ve is null then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
  end if;

  if num_nonnulls(v_co, v_ve) <> 1 then
    -- The buying team opening the page before picking an owner. Not an error — there is simply
    -- nothing to show yet, and saying «forbidden» would read as a permission problem.
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'needs_owner', true, 'wallet_id', null, 'balance', 0,
      'entries', '[]'::jsonb, 'total', 0, 'subscriptions', '[]'::jsonb,
      'side', case when v_team then 'purchasing' else 'owner' end));
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, v_ve, false);
  if v_wallet is null then
    -- No wallet yet is a balance of zero, not an error. Creating one on a read would make looking
    -- at a page a write.
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'needs_owner', false, 'wallet_id', null, 'balance', 0, 'currency', 'SAR',
      'low_balance_threshold', null, 'low', false,
      'entries', '[]'::jsonb, 'total', 0, 'subscriptions', '[]'::jsonb,
      'company_id', v_co, 'vendor_id', v_ve, 'can_manage', v_team,
      'side', case when v_team then 'purchasing' else 'owner' end));
  end if;

  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_row from qvm_new_apps.wallets where wallet_id = v_wallet;

  select coalesce(sum(amount), 0) into v_balance
    from qvm_new_apps.wallet_entries where wallet_id = v_wallet;

  select coalesce(jsonb_agg(to_jsonb(k) - 'n' order by k.entry_id desc), '[]'::jsonb),
         coalesce(max(k.n), 0)
    into v_entries, v_total
    from (select e.entry_id, e.amount, e.balance_after, e.kind, e.source, e.source_id,
                 e.reference, e.description, e.expires_on, e.invoice_url, e.created_at,
                 u.user_name as created_by_name,
                 count(*) over () as n
            from qvm_new_apps.wallet_entries e
            left join qvm_new_apps.user_data u on u.user_id = e.created_by
           where e.wallet_id = v_wallet
           order by e.entry_id desc
           limit least(greatest(coalesce(p_limit, 50), 1), 200)
          offset greatest(coalesce(p_offset, 0), 0)) k;

  select coalesce(jsonb_agg(jsonb_build_object(
           'subscription_id', s.subscription_id, 'service_key', s.service_key,
           'plan_name', s.plan_name, 'amount', s.amount, 'period', s.period,
           'status', s.status, 'started_on', s.started_on, 'renews_on', s.renews_on,
           -- Said by the server so the screen does not decide what «overdue» means.
           'overdue', s.status = 'active' and s.renews_on <= current_date)
         order by s.status, s.renews_on), '[]'::jsonb)
    into v_subs
    from qvm_new_apps.wallet_subscriptions s where s.wallet_id = v_wallet;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'needs_owner', false,
    'wallet_id', v_wallet, 'balance', v_balance, 'currency', v_row.currency,
    'low_balance_threshold', v_row.low_balance_threshold,
    'low', v_row.low_balance_threshold is not null and v_balance < v_row.low_balance_threshold,
    'entries', v_entries, 'total', v_total, 'subscriptions', v_subs,
    'company_id', v_row.company_id, 'vendor_id', v_row.vendor_id,
    'can_manage', true,
    'side', case when v_team then 'purchasing' else 'owner' end));
end
$$;

-- ── Topping up ─────────────────────────────────────────────────────────────────────────────────
-- There is no payment gateway here yet. This records money that arrived — a transfer, a deposit —
-- the same way a supplier payment is recorded, with a reference and a receipt. When a gateway is
-- added it calls this after the payment clears; nothing else has to change.
create or replace function qvm_new_apps.wallet_topup(
  p_company_id  integer default null,
  p_vendor_id   integer default null,
  p_amount      numeric default null,
  p_reference   text default null,
  p_description text default null,
  p_invoice_url text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_wallet bigint;
begin
  -- Only the side that receives the money may say it arrived. An owner topping up their own
  -- balance by typing a number is not a top-up, it is a wish.
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تسجيل الشحن من صلاحية قبارتس');
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الشحن يجب أن تكون أكبر من صفر', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_company_id, p_vendor_id, true);
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'حدد الشركة أو المورد', 'data', null);
  end if;

  return qvm_new_apps.wallet_charge(
    p_wallet_id   => v_wallet,
    p_amount      => p_amount,
    p_kind        => 'topup',
    p_description => p_description,
    p_reference   => p_reference,
    p_source      => 'manual',
    p_invoice_url => p_invoice_url);
end
$$;

create or replace function qvm_new_apps.wallet_set_threshold(
  p_wallet_id bigint,
  p_threshold numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
begin
  if not qvm_new_apps.wallet_can_manage(p_wallet_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if p_threshold is not null and p_threshold < 0 then
    return jsonb_build_object('status', false, 'message', 'الحد لا يمكن أن يكون سالباً', 'data', null);
  end if;
  update qvm_new_apps.wallets set low_balance_threshold = p_threshold
   where wallet_id = p_wallet_id;
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('low_balance_threshold', p_threshold));
end
$$;

-- An operational expense: «مصروف تشغيلي» in the design. Qparts only, and allowed to overdraw,
-- because it records a cost that has already been incurred.
create or replace function qvm_new_apps.wallet_record_expense(
  p_wallet_id   bigint,
  p_amount      numeric,
  p_description text default null,
  p_reference   text default null,
  p_invoice_url text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'تسجيل المصاريف من صلاحية قبارتس', 'data', null);
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة المصروف يجب أن تكون أكبر من صفر', 'data', null);
  end if;
  return qvm_new_apps.wallet_charge(
    p_wallet_id      => p_wallet_id,
    p_amount         => -p_amount,
    p_kind           => 'operational',
    p_description    => p_description,
    p_reference      => p_reference,
    p_source         => 'manual',
    p_invoice_url    => p_invoice_url,
    p_allow_negative => true);
end
$$;

revoke all on function qvm_new_apps.wallet_can_manage(bigint) from public;
revoke all on function qvm_new_apps.wallet_get(integer, integer, integer, integer) from public;
revoke all on function qvm_new_apps.wallet_topup(integer, integer, numeric, text, text, text) from public;
revoke all on function qvm_new_apps.wallet_set_threshold(bigint, numeric) from public;
revoke all on function qvm_new_apps.wallet_record_expense(bigint, numeric, text, text, text) from public;
grant execute on function qvm_new_apps.wallet_get(integer, integer, integer, integer),
                          qvm_new_apps.wallet_topup(integer, integer, numeric, text, text, text),
                          qvm_new_apps.wallet_set_threshold(bigint, numeric),
                          qvm_new_apps.wallet_record_expense(bigint, numeric, text, text, text),
                          qvm_new_apps.wallet_can_manage(bigint)
  to authenticated, service_role;
