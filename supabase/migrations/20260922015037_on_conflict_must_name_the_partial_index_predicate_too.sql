-- ON CONFLICT must name the partial index's predicate too.
--
-- `on conflict (usage_event_id)` matches no index here: the uniqueness is partial
-- (`where usage_event_id is not null`), and a target that omits the predicate does not match it.
-- Postgres raises, the trigger's exception handler swallowed the raise, and the result was an AI
-- event recorded with no charge against it and nothing anywhere saying so.
--
-- This is the fourth time this codebase has been bitten by a partial/nullable unique index:
-- carrier_credentials, integration_usage, ai_credit_party_switch, and now here. The lesson that
-- keeps not sticking is that ON CONFLICT does not search for a usable index — it matches the
-- one you describe, predicate included.
--
-- The exception handler is also narrowed. Swallowing everything was meant to protect the usage
-- record from a billing failure, and it does — but it protected this bug for as long as nobody
-- compared the two tables. It now re-raises as a warning that names the account and amount, and
-- `ai_credit_verify()` exists to be asked the same question on purpose.
create or replace function qvm_new_apps.wallet_charge_ai_usage()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_sar    numeric;
  v_peg    numeric;
  v_markup numeric;
begin
  -- Nothing to bill, and nobody to bill it to. Qparts' own staff running the AI have neither a
  -- company nor a supplier, and that usage is the platform's, not an organisation's.
  if coalesce(new.est_cost_usd, 0) <= 0 then return new; end if;
  if new.company_id is null and new.vendor_id is null then return new; end if;

  select amount into v_peg    from qvm_new_apps.wallet_rates where rate_key = 'ai_usd_to_sar';
  select amount into v_markup from qvm_new_apps.wallet_rates where rate_key = 'ai_markup';
  -- Rounded to the halala. Carrying more precision into a ledger invites a balance that no
  -- statement can reproduce.
  v_sar := round(new.est_cost_usd * coalesce(v_peg, 3.75) * coalesce(v_markup, 1), 2);
  if v_sar <= 0 then return new; end if;

  -- Created on demand: an organisation's first AI call should not need somebody to have set up
  -- a pool first. It opens at zero and goes negative by this one call, which is the true story —
  -- the provider has already been paid by the time this row exists, so the debt is real. The
  -- gate stops the *next* call; it cannot un-run this one.
  v_acct := qvm_new_apps.ai_credit_account_of(new.company_id, new.vendor_id, true);
  if v_acct is null then return new; end if;

  insert into qvm_new_apps.ai_credit_entries
    (account_id, amount, kind, description, party_company_id, party_vendor_id, usage_event_id)
  values (v_acct, -v_sar, 'usage', coalesce(new.action_type, 'AI'),
          new.company_id, new.vendor_id, new.id)
  -- The predicate is part of the target, because the index is partial.
  on conflict (usage_event_id) where usage_event_id is not null do nothing;

  return new;
exception when others then
  -- Still swallowed — the record of what the model did matters more than our ability to bill for
  -- it — but loudly, and with the numbers needed to replay it by hand.
  raise warning 'ai credit: event % (account %, % SAR) was NOT charged: %',
    new.id, v_acct, v_sar, sqlerrm;
  return new;
end
$$;
