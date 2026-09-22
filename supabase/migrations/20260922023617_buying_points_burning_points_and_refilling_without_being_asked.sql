-- Buying points, burning points, and refilling without being asked.

-- ── Buying ─────────────────────────────────────────────────────────────────────────────────────
-- The caller names a quantity of points, never a sum of money. What that costs is the rate's
-- business, and a caller who can name the price can buy the month's credit for a riyal.
create or replace function qvm_new_apps.ai_credit_buy_points(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_points     numeric default null,
  p_note       text    default null,
  -- Set by the automatic path below, so the ledger says which purchases nobody clicked.
  p_automatic  boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_wallet bigint;
  v_price  numeric := qvm_new_apps.ai_point_price();
  v_sar    numeric;
  v_charge jsonb;
  v_entry  bigint;
begin
  if coalesce(p_points, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'عدد النقاط يجب أن يكون أكبر من صفر', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_company_id, p_vendor_id, false);
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'لا توجد محفظة لهذه الجهة', 'data', null);
  end if;
  -- The automatic path has no user behind it, so there is nobody whose permission to check. It
  -- only ever runs for an account that was configured by somebody who did have it.
  if not p_automatic and not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه المحفظة', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_company_id, p_vendor_id, true);
  if v_acct is null then
    return jsonb_build_object('status', false, 'message', 'تعذّر تحديد حساب الرصيد', 'data', null);
  end if;

  v_sar := round(p_points * v_price, 2);

  -- The wallet is charged first and is allowed to refuse. Crediting points before knowing the
  -- money left would hand out AI nobody paid for.
  v_charge := qvm_new_apps.wallet_charge(
    p_wallet_id   => v_wallet,
    p_amount      => -v_sar,
    p_kind        => 'consumption',
    p_description => coalesce(p_note, case when p_automatic
                                           then 'شراء نقاط ذكاء اصطناعي (تلقائي)'
                                           else 'شراء نقاط ذكاء اصطناعي' end),
    p_source      => 'ai_points');

  if not (v_charge ->> 'status')::boolean then
    return v_charge;
  end if;

  insert into qvm_new_apps.ai_credit_entries
    (account_id, points, sar_amount, kind, description, wallet_entry_id, created_by)
  values (v_acct, p_points, v_sar, 'topup',
          coalesce(p_note, case when p_automatic then 'شراء تلقائي' else 'شراء نقاط' end),
          (v_charge -> 'data' ->> 'entry_id')::bigint,
          case when p_automatic then null else auth.uid() end)
  returning entry_id into v_entry;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'account_id', v_acct, 'entry_id', v_entry, 'points', p_points, 'sar', v_sar,
    'balance', qvm_new_apps.ai_credit_balance(v_acct),
    'wallet_balance', v_charge -> 'data' ->> 'balance'));
end
$$;

-- The old money-denominated door, closed. Leaving it would be a second way to credit the pool,
-- and the two would disagree about what a unit is.
drop function if exists qvm_new_apps.ai_credit_topup(integer, integer, numeric, text);

-- ── Refilling ──────────────────────────────────────────────────────────────────────────────────
-- Called after a burn. Returns quietly in every case where it should do nothing, because it runs
-- on the hot path of every AI call and «do nothing» is by far its most common answer.
create or replace function qvm_new_apps.ai_credit_maybe_autotopup(p_account_id bigint)
returns void
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  a       record;
  v_bal   numeric;
  v_res   jsonb;
begin
  select * into a from qvm_new_apps.ai_credit_accounts where account_id = p_account_id;
  if a.account_id is null or not a.auto_topup_enabled then return; end if;

  -- An empty wallet would otherwise mean a failed charge on every single AI call for as long as
  -- it stays empty. One attempt an hour is enough to notice the money arriving.
  if a.auto_topup_failed_at is not null and a.auto_topup_failed_at > now() - interval '1 hour' then
    return;
  end if;

  v_bal := qvm_new_apps.ai_credit_balance(p_account_id);
  if v_bal >= a.auto_topup_threshold then return; end if;

  v_res := qvm_new_apps.ai_credit_buy_points(
    p_company_id => a.company_id,
    p_vendor_id  => a.vendor_id,
    p_points     => a.auto_topup_points,
    p_note       => 'شراء تلقائي عند انخفاض الرصيد',
    p_automatic  => true);

  if (v_res ->> 'status')::boolean then
    update qvm_new_apps.ai_credit_accounts
       set auto_topup_last_at = now(), auto_topup_failed_at = null
     where account_id = p_account_id;
  else
    -- Recorded, not raised. The AI call that triggered this has already happened and must not be
    -- undone because the wallet was short.
    update qvm_new_apps.ai_credit_accounts
       set auto_topup_failed_at = now()
     where account_id = p_account_id;
    raise warning 'ai credit: automatic purchase for account % failed: %',
      p_account_id, v_res ->> 'message';
  end if;
end
$$;

-- ── Burning ────────────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.wallet_charge_ai_usage()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_points numeric;
begin
  -- Nothing to bill, and nobody to bill it to. Qparts' own staff running the AI have neither a
  -- company nor a supplier, and that usage is the platform's, not an organisation's.
  if coalesce(new.est_cost_usd, 0) <= 0 then return new; end if;
  if new.company_id is null and new.vendor_id is null then return new; end if;

  v_points := qvm_new_apps.ai_points_for_usd(new.est_cost_usd);
  if v_points <= 0 then return new; end if;

  -- Created on demand: an organisation's first AI call should not need somebody to have set up
  -- a pool first. It opens at zero and goes negative by this one call, which is the true story —
  -- the provider has already been paid by the time this row exists, so the debt is real. The
  -- gate stops the *next* call; it cannot un-run this one.
  v_acct := qvm_new_apps.ai_credit_account_of(new.company_id, new.vendor_id, true);
  if v_acct is null then return new; end if;

  insert into qvm_new_apps.ai_credit_entries
    (account_id, points, kind, description, party_company_id, party_vendor_id, usage_event_id)
  values (v_acct, -v_points, 'usage', coalesce(new.action_type, 'AI'),
          new.company_id, new.vendor_id, new.id)
  -- The predicate is part of the target, because the index is partial.
  on conflict (usage_event_id) where usage_event_id is not null do nothing;

  -- After the burn, not before: the decision to refill is about the balance this call leaves
  -- behind, and asking first would refill one call too late every time.
  perform qvm_new_apps.ai_credit_maybe_autotopup(v_acct);

  return new;
exception when others then
  -- Still swallowed — the record of what the model did matters more than our ability to bill for
  -- it — but loudly, and with the numbers needed to replay it by hand.
  raise warning 'ai credit: event % (account %, % points) was NOT charged: %',
    new.id, v_acct, v_points, sqlerrm;
  return new;
end
$$;

grant execute on function qvm_new_apps.ai_credit_buy_points(integer, integer, numeric, text, boolean)
  to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_maybe_autotopup(bigint) to service_role;
