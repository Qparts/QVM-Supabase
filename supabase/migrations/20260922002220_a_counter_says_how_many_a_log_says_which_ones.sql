-- A counter says how many. A log says which ones.
--
-- `integration_usage` holds «500 of 500 used» and nothing else. Nobody can ask when, or who, or
-- what was looked up — the number is unarguable and unexaminable at the same time, which is the
-- worst combination for anything that gets deducted from somebody.
--
-- So: an append-only row per consumption, beside the counter. The counter stays the thing the
-- quota check locks and reads, for the same reason `wallet_entries` sits beside a locked wallet
-- row — a sum over a growing log is not what you want to hold a lock across on every request.
-- The two are written in one transaction by one function, so they cannot drift; and where that
-- assumption is wrong, `integration_usage_verify()` below says so out loud.
create table if not exists qvm_new_apps.integration_events (
  event_id        bigserial primary key,
  subscription_id bigint      not null references qvm_new_apps.wallet_subscriptions(subscription_id) on delete cascade,
  service_key     text        not null,
  metric          text        not null,
  -- '' is «account-wide», never null — the same rule the counter's unique index needed.
  scope           text        not null default '',
  period_start    date        not null,
  amount          numeric     not null,
  -- Null is «not a person»: the opening rows below, and anything a scheduled job ever consumes.
  -- Better than inventing an actor, which is what a NOT NULL here would force.
  user_id         uuid,
  -- 'use' is a real consumption. 'opening' is the figure a counter already carried before this
  -- log existed — an opening balance, not a thing anybody did.
  kind            text        not null default 'use',
  -- What was looked up. Free-shaped because a part-number lookup and a message send do not
  -- describe themselves the same way.
  ref             jsonb,
  created_at      timestamptz not null default now(),
  constraint integration_events_kind_ck check (kind in ('use', 'opening'))
);

comment on table qvm_new_apps.integration_events is
  'Append-only. One row per quota consumption. Never updated, never deleted — a log that can be '
  'edited is not evidence of anything, and the counter beside it is only trustworthy because '
  'this cannot be quietly rewritten.';

create index if not exists integration_events_sub_idx
  on qvm_new_apps.integration_events (subscription_id, metric, period_start, scope);
create index if not exists integration_events_recent_idx
  on qvm_new_apps.integration_events (created_at desc);

alter table qvm_new_apps.integration_events enable row level security;

-- Append-only, enforced rather than merely intended. The RPCs are SECURITY DEFINER and this
-- trigger fires for them too, so there is no door that skips it.
create or replace function qvm_new_apps.integration_events_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'integration_events is append-only (attempted %)', tg_op;
end
$$;

drop trigger if exists integration_events_no_change on qvm_new_apps.integration_events;
create trigger integration_events_no_change
  before update or delete on qvm_new_apps.integration_events
  for each row execute function qvm_new_apps.integration_events_append_only();

-- ── The opening figures ────────────────────────────────────────────────────────────────────────
-- The counters already carry numbers from before this log existed. Left alone, every one of them
-- would read as unexplained drift forever. Recorded as what they are: an opening balance nobody
-- performed. Only for counters that have no events yet, so re-running this is harmless.
insert into qvm_new_apps.integration_events
  (subscription_id, service_key, metric, scope, period_start, amount, user_id, kind, ref)
select u.subscription_id, s.service_key, u.metric, u.scope, u.period_start, u.used, null, 'opening',
       jsonb_build_object('note', 'رصيد مستهلك قبل بدء السجل')
  from qvm_new_apps.integration_usage u
  join qvm_new_apps.wallet_subscriptions s using (subscription_id)
 where u.used > 0
   and not exists (select 1 from qvm_new_apps.integration_events e
                    where e.subscription_id = u.subscription_id and e.metric = u.metric
                      and e.period_start = u.period_start and e.scope = u.scope);

-- ── The drift detector ─────────────────────────────────────────────────────────────────────────
-- The counter is only worth trusting while it equals the log. This is the question asked out
-- loud; without it, «they cannot drift» is a belief rather than something anyone checked.
create or replace function qvm_new_apps.integration_usage_verify()
returns jsonb
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select jsonb_build_object('status', true, 'message', 'ok', 'data',
    coalesce(jsonb_agg(jsonb_build_object(
      'subscription_id', d.subscription_id, 'metric', d.metric,
      'period_start', d.period_start, 'scope', d.scope,
      'counter', d.used, 'logged', d.logged, 'drift', d.used - d.logged)), '[]'::jsonb))
  from (
    select u.subscription_id, u.metric, u.period_start, u.scope, u.used,
           coalesce((select sum(e.amount) from qvm_new_apps.integration_events e
                      where e.subscription_id = u.subscription_id and e.metric = u.metric
                        and e.period_start = u.period_start and e.scope = u.scope), 0) as logged
      from qvm_new_apps.integration_usage u) d
  where d.used <> d.logged;
$$;

grant execute on function qvm_new_apps.integration_usage_verify() to authenticated, service_role;
