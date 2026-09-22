-- Consuming a quota writes down who consumed it.
--
-- The counter and the log are written by this one function, in this one transaction. That is the
-- whole reason they can be trusted to agree — two callers, or an UPDATE anywhere else, and the
-- guarantee is gone.
--
-- A `ref` is added: «500 lookups» is a number, «500 lookups, this one was 90915-2B000, by Sara,
-- on Tuesday» is an answer. Passing it is optional, because a caller with nothing useful to say
-- should say nothing rather than invent a label.
--
-- The argument list changes, so the old function is dropped first. `create or replace` with a
-- different signature does not replace — it creates a second function beside the first, and then
-- every call is ambiguous or silently goes to the old one.
drop function if exists qvm_new_apps.integration_consume(integer, text, text, numeric, text);

create or replace function qvm_new_apps.integration_consume(
  p_company_id integer,
  p_service    text,
  p_metric     text,
  p_amount     numeric default 1,
  p_scope      text    default null,
  p_ref        jsonb   default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_wallet bigint;
  v_sub    record;
  v_limit  numeric;
  v_period date := qvm_new_apps.integration_period_start(p_metric);
  -- '' is «account-wide». Never null, so the unique index can do its job.
  v_scope  text := coalesce(p_scope, '');
  v_used   numeric;
  v_id     bigint;
begin
  v_wallet := qvm_new_apps.wallet_of(p_company_id, null, false);
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'لا يوجد اشتراك نشط', 'data',
      jsonb_build_object('reason', 'no_subscription'));
  end if;

  select * into v_sub from qvm_new_apps.wallet_subscriptions
   where wallet_id = v_wallet and service_key = p_service and status = 'active';
  if v_sub.subscription_id is null then
    return jsonb_build_object('status', false, 'message', 'لا يوجد اشتراك نشط', 'data',
      jsonb_build_object('reason', 'no_subscription'));
  end if;

  v_limit := nullif(v_sub.limits ->> p_metric, 'null')::numeric;

  insert into qvm_new_apps.integration_usage (subscription_id, metric, period_start, scope, used)
  values (v_sub.subscription_id, p_metric, v_period, v_scope, 0)
  on conflict (subscription_id, metric, period_start, scope) do nothing;

  -- Locked before it is read, for the same reason wallet_charge locks: two requests arriving
  -- together must not both see «9,999 of 10,000» and both be allowed.
  select usage_id, used into v_id, v_used
    from qvm_new_apps.integration_usage
   where subscription_id = v_sub.subscription_id and metric = p_metric
     and period_start = v_period and scope = v_scope
   for update;

  -- Refused before anything is written. A rejected request consumed nothing, so it has no place
  -- in a log of what was consumed — the quota page answers «what did we spend», not «what did we
  -- try», and mixing the two makes the first question unanswerable.
  if v_limit is not null and v_used + p_amount > v_limit then
    return jsonb_build_object('status', false, 'message', 'تجاوزت حد الباقة', 'data',
      jsonb_build_object('reason', 'over_quota', 'limit', v_limit, 'used', v_used,
                         'requested', p_amount, 'remaining', greatest(v_limit - v_used, 0)));
  end if;

  update qvm_new_apps.integration_usage
     set used = used + p_amount, updated_at = now()
   where usage_id = v_id;

  -- Same transaction as the line above, on purpose. If either can happen without the other, the
  -- counter stops being explainable by the log and nobody finds out until they go looking.
  insert into qvm_new_apps.integration_events
    (subscription_id, service_key, metric, scope, period_start, amount, user_id, kind, ref)
  values (v_sub.subscription_id, p_service, p_metric, v_scope, v_period, p_amount,
          auth.uid(), 'use', p_ref);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'limit', v_limit,
    'unlimited', v_limit is null,
    'used', v_used + p_amount,
    'remaining', case when v_limit is null then null else v_limit - v_used - p_amount end));
end
$$;

grant execute on function qvm_new_apps.integration_consume(integer, text, text, numeric, text, jsonb)
  to authenticated, service_role;
