-- AI usage comes out of the pool, not the wallet.
--
-- `wallet_charge_ai_usage` charged every AI event straight to the wallet in SAR. Now that credit
-- is *bought* from the wallet, leaving that in place would bill the same model call twice: once
-- when the organisation bought the credit, once when it used it.
--
-- So the trigger changes what it debits, and nothing else. Same conversion, same rates, same
-- rounding, same refusal to let a logging failure roll back the event that says the AI ran —
-- the record of what the model did matters more than our ability to bill for it.
--
-- NOTE: the ON CONFLICT below names a partial index without its predicate, so it raises and the
-- exception handler swallows it — the charge silently never happens. Fixed two minutes later in
-- 20260922015037_on_conflict_must_name_the_partial_index_predicate_too.sql. Kept because it is
-- what the database ran.
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
  -- The unique index on usage_event_id is the real guard; this keeps a re-fired trigger quiet
  -- rather than turning it into an error that rolls back the usage record.
  on conflict (usage_event_id) do nothing;

  return new;
exception when others then
  raise warning 'ai credit: could not charge ai_usage_events %: %', new.id, sqlerrm;
  return new;
end
$$;

-- ── The drift detector ─────────────────────────────────────────────────────────────────────────
-- Every billable AI event should have exactly one entry against it. This asks whether that is
-- true, rather than leaving it as something the trigger is believed to guarantee.
create or replace function qvm_new_apps.ai_credit_verify()
returns jsonb
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'unbilled_events', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'usd', e.est_cost_usd,
               'company_id', e.company_id, 'vendor_id', e.vendor_id)), '[]'::jsonb)
        from public.ai_usage_events e
       where coalesce(e.est_cost_usd, 0) > 0
         and (e.company_id is not null or e.vendor_id is not null)
         and not exists (select 1 from qvm_new_apps.ai_credit_entries c
                          where c.usage_event_id = e.id)),
    -- Usage that is not attributed to anybody. Not an error — it is the platform's own — but it
    -- is the number that explains why a customer's page looks quieter than the provider's bill.
    'unattributed_usd', (
      select coalesce(round(sum(e.est_cost_usd)::numeric, 4), 0)
        from public.ai_usage_events e
       where coalesce(e.est_cost_usd, 0) > 0
         and e.company_id is null and e.vendor_id is null)));
$$;

grant execute on function qvm_new_apps.ai_credit_verify() to authenticated, service_role;
