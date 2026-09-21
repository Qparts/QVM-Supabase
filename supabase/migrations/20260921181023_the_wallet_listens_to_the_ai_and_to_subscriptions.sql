-- The wallet listens where the money is actually spent.
--
-- Every AI call in this system — the invoice reader, part extraction, the inbox assistant, the
-- enrichment batches — already lands one row in ai_usage_events. Charging from a trigger on that
-- table rather than from each caller means there is no path that spends without being billed,
-- including paths written after this. A caller that forgets to call the wallet is the failure
-- mode this avoids.
--
-- The trigger NEVER raises. The event is logged after the work is done and the money is already
-- spent with the provider; refusing to record it would lose the record, not the cost. So it
-- charges with overdraft allowed and lets the balance go negative — a negative balance is a true
-- statement about an account that owes us, and it is visible on the page.
--
-- Stopping the work BEFORE it runs is a different feature and belongs to the caller:
-- wallet_can_spend() is there for that, and nothing calls it yet.
create or replace function qvm_new_apps.wallet_charge_ai_usage()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_wallet bigint;
  v_sar    numeric;
  v_peg    numeric;
  v_markup numeric;
begin
  -- Nothing to bill, and nobody to bill it to.
  if coalesce(new.est_cost_usd, 0) <= 0 then return new; end if;
  if new.company_id is null and new.vendor_id is null then return new; end if;

  select amount into v_peg    from qvm_new_apps.wallet_rates where rate_key = 'ai_usd_to_sar';
  select amount into v_markup from qvm_new_apps.wallet_rates where rate_key = 'ai_markup';
  -- Rounded to the halala. Carrying more precision into a ledger invites a balance that no
  -- statement can reproduce.
  v_sar := round(new.est_cost_usd * coalesce(v_peg, 3.75) * coalesce(v_markup, 1), 2);
  if v_sar <= 0 then return new; end if;

  v_wallet := qvm_new_apps.wallet_of(new.company_id, new.vendor_id, true);
  if v_wallet is null then return new; end if;

  perform qvm_new_apps.wallet_charge(
    p_wallet_id      => v_wallet,
    p_amount         => -v_sar,
    p_kind           => 'consumption',
    p_description    => coalesce(new.action_type, 'AI'),
    p_reference      => 'AI-' || new.id,
    p_source         => 'ai',
    p_source_id      => new.id::text,
    p_allow_negative => true);
  return new;
exception when others then
  -- The usage record matters more than the charge. A failure here is logged and swallowed rather
  -- than rolling back the event that says the AI ran.
  raise warning 'wallet: could not charge ai_usage_events %: %', new.id, sqlerrm;
  return new;
end
$$;

drop trigger if exists wallet_charge_ai_usage_trg on public.ai_usage_events;
create trigger wallet_charge_ai_usage_trg
  after insert on public.ai_usage_events
  for each row execute function qvm_new_apps.wallet_charge_ai_usage();

-- ── Subscriptions ──────────────────────────────────────────────────────────────────────────────
-- Subscribing charges the first period immediately: an integration that starts working before it
-- is paid for is one that can be used for free by cancelling on day 29.
create or replace function qvm_new_apps.wallet_subscribe(
  p_wallet_id   bigint,
  p_service_key text,
  p_plan_name   text,
  p_amount      numeric,
  p_period      text default 'monthly')
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_renews date;
  v_id     bigint;
  v_charge jsonb;
begin
  if not qvm_new_apps.wallet_can_manage(p_wallet_id) then
    return jsonb_build_object('status', false, 'message', 'الاشتراك من صلاحية مالك المحفظة', 'data', null);
  end if;
  if p_period not in ('monthly','yearly') then
    return jsonb_build_object('status', false, 'message', 'مدة اشتراك غير معروفة', 'data', null);
  end if;
  if exists (select 1 from qvm_new_apps.wallet_subscriptions
              where wallet_id = p_wallet_id and service_key = p_service_key and status = 'active') then
    return jsonb_build_object('status', false, 'message', 'الاشتراك قائم بالفعل', 'data', null);
  end if;

  v_renews := current_date + (case when p_period = 'yearly' then interval '1 year'
                                   else interval '1 month' end);

  -- Charged first. If the balance will not cover it there is no subscription to cancel later.
  if coalesce(p_amount, 0) > 0 then
    v_charge := qvm_new_apps.wallet_charge(
      p_wallet_id   => p_wallet_id,
      p_amount      => -p_amount,
      p_kind        => 'subscription',
      p_description => coalesce(p_plan_name, p_service_key),
      p_reference   => upper(p_service_key),
      p_source      => 'integration',
      p_source_id   => p_service_key,
      p_expires_on  => v_renews);
    if not coalesce((v_charge->>'status')::boolean, false) then
      return v_charge;
    end if;
  end if;

  insert into qvm_new_apps.wallet_subscriptions
    (wallet_id, service_key, plan_name, amount, period, renews_on, created_by)
  values (p_wallet_id, p_service_key, p_plan_name, coalesce(p_amount, 0), p_period, v_renews, auth.uid())
  returning subscription_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'subscription_id', v_id, 'renews_on', v_renews, 'balance', v_charge->'data'->'balance'));
end
$$;

-- Cancelling does not refund. The period already charged runs to its end date, which is what
-- renews_on already says — so there is nothing to give back and nothing to stop.
create or replace function qvm_new_apps.wallet_cancel_subscription(p_subscription_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_wallet bigint;
begin
  select wallet_id into v_wallet from qvm_new_apps.wallet_subscriptions
   where subscription_id = p_subscription_id;
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'الاشتراك غير موجود', 'data', null);
  end if;
  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'الإلغاء من صلاحية مالك المحفظة', 'data', null);
  end if;

  update qvm_new_apps.wallet_subscriptions
     set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
   where subscription_id = p_subscription_id and status = 'active';

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('subscription_id', p_subscription_id));
end
$$;

-- Renewals. Written now, scheduled by nobody yet — a subscription whose renews_on has passed is
-- simply overdue until something calls this. Said plainly rather than left to be discovered:
-- there is no cron on this.
create or replace function qvm_new_apps.wallet_subscriptions_renew_due()
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  r        record;
  v_charge jsonb;
  v_ok     integer := 0;
  v_failed jsonb := '[]'::jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  for r in select * from qvm_new_apps.wallet_subscriptions
            where status = 'active' and renews_on <= current_date
            order by subscription_id
  loop
    v_charge := qvm_new_apps.wallet_charge(
      p_wallet_id   => r.wallet_id,
      p_amount      => -r.amount,
      p_kind        => 'subscription',
      p_description => coalesce(r.plan_name, r.service_key),
      p_reference   => upper(r.service_key),
      p_source      => 'integration',
      p_source_id   => r.service_key,
      p_expires_on  => r.renews_on + (case when r.period = 'yearly' then interval '1 year'
                                           else interval '1 month' end));
    if coalesce((v_charge->>'status')::boolean, false) then
      update qvm_new_apps.wallet_subscriptions
         set renews_on = renews_on + (case when period = 'yearly' then interval '1 year'
                                           else interval '1 month' end)
       where subscription_id = r.subscription_id;
      v_ok := v_ok + 1;
    else
      -- Left active and left due. An unpaid renewal is a debt to collect, not a subscription to
      -- silently cancel on someone who is one top-up away from paying it.
      v_failed := v_failed || jsonb_build_object(
        'subscription_id', r.subscription_id, 'service', r.service_key,
        'reason', v_charge->>'message');
    end if;
  end loop;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('renewed', v_ok, 'failed', v_failed));
end
$$;

revoke all on function qvm_new_apps.wallet_subscribe(bigint, text, text, numeric, text) from public;
revoke all on function qvm_new_apps.wallet_cancel_subscription(bigint) from public;
revoke all on function qvm_new_apps.wallet_subscriptions_renew_due() from public;
grant execute on function qvm_new_apps.wallet_subscribe(bigint, text, text, numeric, text),
                          qvm_new_apps.wallet_cancel_subscription(bigint),
                          qvm_new_apps.wallet_subscriptions_renew_due()
  to authenticated, service_role;
