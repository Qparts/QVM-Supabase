-- A plan that does not enforce its limit is a price tag.
--
-- Every package in the catalogue sells a number: 10,000 messages a month, 2,000 lookups, 600 a day
-- per number. Charging for that and then letting usage run past it is not a subscription — it is a
-- receipt. This is the counter that makes the number mean something.
--
-- One row per (subscription, metric, period). The period is a date rather than a timestamp because
-- every quota in the catalogue is «per month» or «per day», and storing the first day of the window
-- makes «which window am I in» a date_trunc instead of a range comparison.
--
-- NOTE: `scope` is created nullable here and corrected two migrations later — a null scope does
-- not collide in the unique index, so ON CONFLICT never matched and each increment inserted a new
-- counter. See 20260921194532.
create table if not exists qvm_new_apps.integration_usage (
  usage_id        bigserial primary key,
  subscription_id bigint not null
    references qvm_new_apps.wallet_subscriptions(subscription_id) on delete cascade,
  metric          text not null,
  period_start    date not null,
  scope           text,
  used            numeric not null default 0,
  updated_at      timestamptz not null default now(),
  unique (subscription_id, metric, period_start, scope)
);

create index if not exists integration_usage_sub_idx
  on qvm_new_apps.integration_usage (subscription_id, period_start);

alter table qvm_new_apps.integration_usage enable row level security;

comment on table qvm_new_apps.integration_usage is
  'What a subscription has used in the current window. The counter''s metric key is the same key '
  'the plan''s limits object uses, so a limit and its counter cannot drift apart by spelling.';

-- Snapshot, not a foreign key to the live plan: if the catalogue's Business tier goes from 10,000
-- to 8,000 next quarter, a company that bought 10,000 keeps 10,000 until it renews. Reading the
-- limit off the live row would silently reprice what somebody already paid for.
alter table qvm_new_apps.wallet_subscriptions
  add column if not exists plan_key text,
  add column if not exists limits   jsonb not null default '{}'::jsonb;

comment on column qvm_new_apps.wallet_subscriptions.limits is
  'The plan''s limits as they were when bought. A snapshot on purpose — a catalogue change must '
  'not retroactively shrink what somebody already paid for.';

create or replace function qvm_new_apps.integration_period_start(p_metric text)
returns date
language sql
immutable
as $$
  -- Anything ending in _day resets at midnight; everything else is monthly. The convention is in
  -- the metric name so a new metric does not need a case added here.
  select case when p_metric like '%_day' or p_metric like 'daily_%'
              then current_date
              else date_trunc('month', current_date)::date end;
$$;

-- What is left, without consuming any of it. For a screen, or for a caller that wants to warn
-- before doing the work. Like wallet_can_spend, it is an answer for this instant and not a hold.
create or replace function qvm_new_apps.integration_quota(
  p_company_id integer,
  p_service    text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_wallet bigint; v_rows jsonb;
begin
  v_wallet := qvm_new_apps.wallet_of(p_company_id, null, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'service_key', s.service_key, 'plan_key', s.plan_key, 'metric', m.key,
           'limit', nullif(m.value::text, 'null')::numeric,
           'used', coalesce(u.used, 0),
           'remaining', case when nullif(m.value::text, 'null') is null then null
                             else greatest(nullif(m.value::text,'null')::numeric - coalesce(u.used, 0), 0) end,
           'period_start', qvm_new_apps.integration_period_start(m.key))
         order by s.service_key, m.key), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.wallet_subscriptions s
    cross join lateral jsonb_each(s.limits) m(key, value)
    left join qvm_new_apps.integration_usage u
           on u.subscription_id = s.subscription_id
          and u.metric = m.key
          and u.period_start = qvm_new_apps.integration_period_start(m.key)
          and u.scope is null
   where s.wallet_id = v_wallet and s.status = 'active'
     and (p_service is null or s.service_key = p_service);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', v_rows);
end
$$;

revoke all on function qvm_new_apps.integration_quota(integer, text) from public;
grant execute on function qvm_new_apps.integration_quota(integer, text) to authenticated, service_role;
