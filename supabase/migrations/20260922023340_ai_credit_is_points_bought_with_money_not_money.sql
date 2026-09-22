-- AI credit is points, bought with money. It is not money.
--
-- The pool was denominated in SAR, which made it a second wallet rather than a meter — and it
-- meant the AI still read as «spending riyals», which is exactly the thing that was supposed to
-- stop. Credit is now points: an organisation buys a quantity, the model burns a quantity, and
-- the only place money appears is the moment of purchase.
--
-- Three numbers, all Qparts', all in `wallet_rates` where the others already live:
--
--   ai_point_sar     what one point costs the customer to buy
--   ai_usd_to_sar    the peg, unchanged
--   ai_markup        the margin, unchanged
--
-- Buying:  points × ai_point_sar                          = SAR out of the wallet
-- Burning: usd × ai_usd_to_sar × ai_markup ÷ ai_point_sar = points out of the pool
--
-- The margin lives in the gap between those two, which is where it belongs and where it can be
-- moved without touching any code.
insert into qvm_new_apps.wallet_rates (rate_key, amount, unit, description)
values ('ai_point_sar', 0.01, 'SAR per point',
        'What one AI point costs to buy. 0.01 means 100 points per riyal.')
on conflict (rate_key) do nothing;

-- ── The column means points now ────────────────────────────────────────────────────────────────
-- Renamed rather than reinterpreted. A column called `amount` holding points is how somebody
-- later adds two numbers that are not the same kind of thing.
alter table qvm_new_apps.ai_credit_entries rename column amount to points;

-- What a top-up actually cost. Null on usage rows: burning points costs no money at the moment
-- it happens, the money was spent when they were bought.
alter table qvm_new_apps.ai_credit_entries
  add column if not exists sar_amount numeric;

alter table qvm_new_apps.ai_credit_entries
  rename constraint ai_credit_entries_amount_ck to ai_credit_entries_points_ck;

comment on column qvm_new_apps.ai_credit_entries.points is
  'Signed movement in AI points. Positive buys, negative burns. Never money — see sar_amount.';
comment on column qvm_new_apps.ai_credit_entries.sar_amount is
  'What this movement cost in SAR, on a top-up. Null on usage: the money left when the points '
  'were bought, not when they were spent.';

-- ── The rows already written were SAR ──────────────────────────────────────────────────────────
-- The append-only trigger refuses this, correctly — it is doing exactly the job it was added for,
-- and the first attempt at this migration was stopped by it. Rewriting history is a real act and
-- it should look like one, so the guard is lifted by name, for these statements, and put back
-- three lines later. That is different from a table that was never protected.
--
-- Converted rather than left: a ledger whose numbers silently change meaning is worse than an
-- empty one. The SAR the top-ups really were is preserved beside them.
alter table qvm_new_apps.ai_credit_entries disable trigger ai_credit_entries_no_change;

update qvm_new_apps.ai_credit_entries
   set sar_amount = points
 where kind = 'topup' and sar_amount is null;

update qvm_new_apps.ai_credit_entries
   set points = round(points / (select amount from qvm_new_apps.wallet_rates
                                 where rate_key = 'ai_point_sar'), 2);

alter table qvm_new_apps.ai_credit_entries enable trigger ai_credit_entries_no_change;

-- ── Points, from a dollar of provider cost ─────────────────────────────────────────────────────
create or replace function qvm_new_apps.ai_points_for_usd(p_usd numeric)
returns numeric
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select case when coalesce(p_usd, 0) <= 0 then 0 else
    round(
      p_usd
      * coalesce((select amount from qvm_new_apps.wallet_rates where rate_key = 'ai_usd_to_sar'), 3.75)
      * coalesce((select amount from qvm_new_apps.wallet_rates where rate_key = 'ai_markup'), 1)
      / nullif(coalesce((select amount from qvm_new_apps.wallet_rates where rate_key = 'ai_point_sar'), 0.01), 0)
    , 2) end;
$$;

create or replace function qvm_new_apps.ai_point_price()
returns numeric
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select coalesce((select amount from qvm_new_apps.wallet_rates where rate_key = 'ai_point_sar'), 0.01);
$$;

create or replace function qvm_new_apps.ai_credit_balance(p_account_id bigint)
returns numeric
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select coalesce(sum(points), 0) from qvm_new_apps.ai_credit_entries
   where account_id = p_account_id;
$$;

grant execute on function qvm_new_apps.ai_points_for_usd(numeric) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_point_price() to authenticated, service_role;
