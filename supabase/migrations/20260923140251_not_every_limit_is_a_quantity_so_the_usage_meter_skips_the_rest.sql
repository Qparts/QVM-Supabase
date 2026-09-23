-- Not every limit is a quantity, so the usage meter skips the rest.
--
-- `integrations_market` builds a usage row for every key in a subscription's `limits` and casts
-- each value to numeric. That held until the comparison sheet needed «Webhooks / API» and «الدعم»,
-- which went into `limits` beside the quotas — with a deliberate note saying they belong there so
-- that a plan's promises live in one object.
--
-- What that note did not do was check who else reads `limits`. This did, and the moment a company
-- subscribed to a WhatsApp plan the whole marketplace answered
-- «invalid input syntax for type numeric: "true"». The page showed one error banner and no
-- services at all — and not only for that company: an operator opening any company hit it too,
-- because the plans are read for every service whether subscribed or not.
--
-- The catalogue stays as it is. A plan's promises do belong in one place; it is the meter that
-- was wrong to assume all of them are countable. `true` is not a quota and neither is
-- «تذاكر + واتساب», so they are not metered.
--
-- Written out in full rather than patched with replace(). Two attempts at a targeted patch put
-- the predicate in the wrong clause and then mangled its quoting; at that point the surgery is
-- costing more than the rewrite.
create or replace function qvm_new_apps.integrations_market(p_company_id integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_op     boolean := qvm_new_apps.wallet_is_operator();
  v_co     integer := p_company_id;
  v_wallet bigint;
  v_balance numeric := 0;
  v_rows   jsonb;
begin
  -- An owner never picks whose marketplace to open.
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
    if v_co is null then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
  end if;

  if v_co is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'needs_owner', true, 'services', '[]'::jsonb, 'balance', 0,
      'side', case when v_op then 'operator' else 'owner' end));
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if v_wallet is not null then
    select coalesce(sum(amount), 0) into v_balance
      from qvm_new_apps.wallet_entries where wallet_id = v_wallet;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'service_key', s.service_key,
    'name_ar', s.name_ar, 'name_en', s.name_en,
    'category', s.category, 'kind', s.kind,
    'tagline_ar', s.tagline_ar, 'tagline_en', s.tagline_en,
    'blurb_ar', s.blurb_ar, 'blurb_en', s.blurb_en,
    'badge', s.badge, 'accent', s.accent, 'logo_url', s.logo_url,
    'metrics', s.metrics,
    'connected', qvm_new_apps.integration_connected(v_co, s.service_key),
    'plans', (select coalesce(jsonb_agg(jsonb_build_object(
                'plan_key', p.plan_key, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'price', p.price, 'period', p.period, 'limits', p.limits,
                'is_popular', p.is_popular) order by p.sort_order), '[]'::jsonb)
                from qvm_new_apps.integration_plans p
               where p.service_key = s.service_key and p.is_active),
    'subscription', sub.row,
    -- What this company has left on its current plan, metric by metric.
    'usage', (select coalesce(jsonb_agg(jsonb_build_object(
                'metric', m.key,
                'limit', nullif(m.value::text, 'null')::numeric,
                'used', coalesce(u.used, 0)) order by m.key), '[]'::jsonb)
                from jsonb_each(coalesce(sub.limits, '{}'::jsonb)) m(key, value)
                left join qvm_new_apps.integration_usage u
                       on u.subscription_id = sub.subscription_id
                      and u.metric = m.key
                      and u.period_start = qvm_new_apps.integration_period_start(m.key)
                      and u.scope = ''
               -- A quota is a number, or null for uncapped. Anything else in `limits` is a
               -- promise the plan makes, not an allowance it meters.
               where jsonb_typeof(m.value) in ('number', 'null')),
    -- For a connect-type service: is an account attached, and whose.
    'connection', case when s.kind = 'connect' then (
        select jsonb_build_object(
                 'attached', cc.credential_id is not null,
                 'environment', cc.environment,
                 'is_active', cc.is_active,
                 'own_account', cc.company_id is not null,
                 'last_test_ok', cc.last_test_ok,
                 'last_test_at', cc.last_test_at,
                 -- The key itself never leaves the server. Four characters are enough to tell two
                 -- tokens apart, which is the only thing a person needs the screen for.
                 'token_hint', case when cc.api_token is null then null
                                    else '••••' || right(cc.api_token, 4) end)
          from qvm_new_apps.carrier_credentials cc
          join qvm_new_apps.list_data ld on ld.list_data_id = cc.carrier_id
         where lower(ld.list_data) = s.service_key
           and (cc.company_id = v_co or cc.company_id is null)
         order by cc.company_id nulls last
         limit 1) end,
    'can_subscribe', s.kind = 'plan' and s.is_active and sub.subscription_id is null,
    'blocked_reason', case
      when s.kind = 'soon' then 'coming_soon'
      when sub.subscription_id is not null then 'already_subscribed'
      when s.kind = 'connect' then 'connect_only'
      else null end)
    order by s.sort_order), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.integration_services s
    left join lateral (
      select w.subscription_id, w.limits,
             jsonb_build_object(
               'subscription_id', w.subscription_id, 'plan_key', w.plan_key,
               'plan_name', w.plan_name, 'amount', w.amount, 'period', w.period,
               'renews_on', w.renews_on, 'status', w.status,
               'overdue', w.renews_on <= current_date) as row
        from qvm_new_apps.wallet_subscriptions w
       where w.wallet_id = v_wallet and w.service_key = s.service_key and w.status = 'active'
       limit 1) sub on true
   where s.is_active;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'needs_owner', false, 'company_id', v_co, 'balance', v_balance,
    'wallet_id', v_wallet, 'services', v_rows,
    'can_manage', v_wallet is null or qvm_new_apps.wallet_can_manage(v_wallet),
    'side', case when v_op then 'operator' else 'owner' end));
end
$function$;
