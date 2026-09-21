-- A null scope made every increment a new counter.
--
-- integration_usage was unique on (subscription_id, metric, period_start, scope), and scope is
-- null for an account-wide quota — which is most of them. NULL is not equal to NULL in a unique
-- index, so ON CONFLICT never matched and each call inserted a fresh row at zero. Three lookups
-- against one monthly allowance produced three counters.
--
-- It refused at 501 in testing anyway, which is the part worth saying out loud: the SELECT … FOR
-- UPDATE has no ORDER BY, so it happened to keep picking the row that had the count. With a
-- different plan or a different moment it would have picked a zero and let the quota run forever.
-- A test that passes by luck is not a test that passed.
--
-- This is the same trap avoided one migration earlier on carrier_credentials, where partial
-- indexes were used precisely because NULL does not collide. The fix here is the other option:
-- make the column NOT NULL with '' meaning «account-wide», so ordinary uniqueness works and there
-- is no null left to reason about.

-- Merge first, while the duplicates are still distinguishable. Setting scope to '' before this
-- would collide with the constraint on the second row of each group.
with merged as (
  select subscription_id, metric, period_start, scope,
         sum(used) as total, min(usage_id) as keep_id
    from qvm_new_apps.integration_usage
   group by subscription_id, metric, period_start, scope
)
update qvm_new_apps.integration_usage u
   set used = m.total, updated_at = now()
  from merged m
 where u.usage_id = m.keep_id and u.used is distinct from m.total;

delete from qvm_new_apps.integration_usage u
 using (select subscription_id, metric, period_start, scope, min(usage_id) as keep_id
          from qvm_new_apps.integration_usage
         group by subscription_id, metric, period_start, scope) m
 where u.subscription_id = m.subscription_id
   and u.metric = m.metric
   and u.period_start = m.period_start
   and u.scope is not distinct from m.scope
   and u.usage_id <> m.keep_id;

update qvm_new_apps.integration_usage set scope = '' where scope is null;

alter table qvm_new_apps.integration_usage
  alter column scope set default '',
  alter column scope set not null;

comment on column qvm_new_apps.integration_usage.scope is
  'Which number or mailbox this counter is for. '''' means account-wide — NOT NULL on purpose, '
  'because a NULL here does not collide in the unique index and every increment becomes a new row.';

create or replace function qvm_new_apps.integration_consume(
  p_company_id integer,
  p_service    text,
  p_metric     text,
  p_amount     numeric default 1,
  p_scope      text default null)
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

  -- No limit recorded for this metric means the plan does not cap it. Unlimited is stored as null
  -- rather than a big number precisely so this reads as «uncapped», not «probably enough».
  if v_limit is null then
    update qvm_new_apps.integration_usage
       set used = used + p_amount, updated_at = now() where usage_id = v_id;
    return jsonb_build_object('status', true, 'message', 'ok',
      'data', jsonb_build_object('limit', null, 'unlimited', true, 'used', v_used + p_amount));
  end if;

  if v_used + p_amount > v_limit then
    return jsonb_build_object('status', false, 'message', 'تجاوزت حد الباقة', 'data',
      jsonb_build_object('reason', 'over_quota', 'limit', v_limit, 'used', v_used,
                         'requested', p_amount, 'remaining', greatest(v_limit - v_used, 0)));
  end if;

  update qvm_new_apps.integration_usage
     set used = used + p_amount, updated_at = now()
   where usage_id = v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'limit', v_limit, 'used', v_used + p_amount, 'remaining', v_limit - v_used - p_amount));
end
$$;

-- The two readers joined on `u.scope is null`, which now matches nothing.
do $do$
declare
  v_fn   text;
  v_oid  oid;
  v_def  text;
  v_hits integer;
begin
  foreach v_fn in array array['integration_quota','integrations_market'] loop
    select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'qvm_new_apps' and p.proname = v_fn;
    v_def := pg_get_functiondef(v_oid);
    v_hits := (length(v_def) - length(replace(v_def, 'u.scope is null', '')))
              / length('u.scope is null');
    if v_hits <> 1 then
      raise exception '%: expected one scope-is-null join, found %', v_fn, v_hits;
    end if;
    execute replace(v_def, 'u.scope is null', 'u.scope = ''''');
  end loop;
end
$do$;

revoke all on function qvm_new_apps.integration_consume(integer, text, text, numeric, text) from public;
grant execute on function qvm_new_apps.integration_consume(integer, text, text, numeric, text) to service_role;
