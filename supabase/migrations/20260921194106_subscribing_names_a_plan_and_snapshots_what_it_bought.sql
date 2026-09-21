-- Subscribing names a plan, and takes a copy of what that plan bought.
--
-- wallet_subscribe took a free-text name and a price, which was right while there was no
-- catalogue. Now there is one, and two things follow.
--
-- The price is read from the plan rather than passed in. A caller that can name its own price can
-- buy the Pro tier for one riyal, and the only thing standing between the browser and that is
-- whether somebody remembered to validate it. Reading it from the catalogue removes the question.
--
-- The limits are copied onto the subscription instead of being looked up through the plan later.
-- If Business goes from 10,000 messages to 8,000 next quarter, a company that bought 10,000 keeps
-- 10,000 until it renews; a live lookup would silently shrink what somebody already paid for.
create or replace function qvm_new_apps.wallet_subscribe(
  p_wallet_id   bigint,
  p_service_key text,
  p_plan_key    text,
  p_period      text default 'monthly')
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_plan   record;
  v_renews date;
  v_id     bigint;
  v_charge jsonb;
begin
  if not qvm_new_apps.wallet_can_manage(p_wallet_id) then
    return jsonb_build_object('status', false, 'message', 'الاشتراك من صلاحية مالك المحفظة', 'data', null);
  end if;

  select * into v_plan from qvm_new_apps.integration_plans
   where service_key = p_service_key and plan_key = p_plan_key and is_active;
  if v_plan.plan_id is null then
    return jsonb_build_object('status', false, 'message', 'الباقة غير متاحة', 'data', null);
  end if;

  -- A service that is announced but not ready cannot be bought, however the request was formed.
  if exists (select 1 from qvm_new_apps.integration_services
              where service_key = p_service_key and (kind = 'soon' or not is_active)) then
    return jsonb_build_object('status', false, 'message', 'الخدمة غير متاحة بعد', 'data', null);
  end if;

  if exists (select 1 from qvm_new_apps.wallet_subscriptions
              where wallet_id = p_wallet_id and service_key = p_service_key and status = 'active') then
    return jsonb_build_object('status', false, 'message', 'الاشتراك قائم بالفعل', 'data', null);
  end if;

  v_renews := current_date + (case when coalesce(p_period, v_plan.period) = 'yearly'
                                   then interval '1 year' else interval '1 month' end);

  -- Charged before the subscription exists. An integration that works before it is paid for is
  -- free to anyone who cancels on day 29.
  if v_plan.price > 0 then
    v_charge := qvm_new_apps.wallet_charge(
      p_wallet_id   => p_wallet_id,
      p_amount      => -v_plan.price,
      p_kind        => 'subscription',
      p_description => v_plan.name_ar,
      p_reference   => upper(p_service_key) || '-' || upper(p_plan_key),
      p_source      => 'integration',
      p_source_id   => p_service_key,
      p_expires_on  => v_renews);
    if not coalesce((v_charge->>'status')::boolean, false) then
      return v_charge;
    end if;
  end if;

  insert into qvm_new_apps.wallet_subscriptions
    (wallet_id, service_key, plan_key, plan_name, amount, period, renews_on, limits, created_by)
  values (p_wallet_id, p_service_key, p_plan_key, v_plan.name_ar, v_plan.price,
          coalesce(p_period, v_plan.period), v_renews, v_plan.limits, auth.uid())
  returning subscription_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'subscription_id', v_id, 'plan_key', p_plan_key, 'price', v_plan.price,
    'renews_on', v_renews, 'limits', v_plan.limits,
    'balance', v_charge->'data'->'balance'));
end
$$;

-- The old five-argument shape is dropped rather than left beside the new one: it let the caller
-- set the price, which is the thing this change exists to stop.
drop function if exists qvm_new_apps.wallet_subscribe(bigint, text, text, numeric, text);

-- Changing plan: cancel the old, take the new. Not a separate «upgrade» path, because the
-- difference between upgrade and downgrade is only which number is bigger, and pro-rating is a
-- policy nobody has set yet. Said plainly: the remainder of the current period is not refunded.
create or replace function qvm_new_apps.wallet_change_plan(
  p_wallet_id   bigint,
  p_service_key text,
  p_plan_key    text)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_old bigint;
begin
  if not qvm_new_apps.wallet_can_manage(p_wallet_id) then
    return jsonb_build_object('status', false, 'message', 'تغيير الباقة من صلاحية مالك المحفظة', 'data', null);
  end if;

  select subscription_id into v_old from qvm_new_apps.wallet_subscriptions
   where wallet_id = p_wallet_id and service_key = p_service_key and status = 'active';

  if v_old is not null then
    update qvm_new_apps.wallet_subscriptions
       set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     where subscription_id = v_old;
  end if;

  return qvm_new_apps.wallet_subscribe(p_wallet_id, p_service_key, p_plan_key);
end
$$;

-- The renewal loop reads the price off the subscription, which is the price that was agreed. It
-- must not re-read the catalogue, or a price rise would apply to everyone silently at renewal
-- instead of being a decision somebody makes.

revoke all on function qvm_new_apps.wallet_subscribe(bigint, text, text, text) from public;
revoke all on function qvm_new_apps.wallet_change_plan(bigint, text, text) from public;
grant execute on function qvm_new_apps.wallet_subscribe(bigint, text, text, text),
                          qvm_new_apps.wallet_change_plan(bigint, text, text)
  to authenticated, service_role;
