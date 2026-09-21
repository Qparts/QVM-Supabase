-- A shipment is paid for before it is created, not after.
--
-- This is the difference between the carrier and the AI, and it decides the whole design.
--
-- AI usage is charged after the fact: by the time the event is logged the provider has already
-- been billed, so the wallet records the cost and is allowed to go negative — refusing would lose
-- the record, not the cost. A shipment is the opposite. Nothing has been spent until we ask the
-- carrier to collect, so the money can and must be checked first. A dispatch that succeeds with an
-- empty wallet is a debt nobody agreed to.
--
-- So: quote, reserve, dispatch. The reserve is a real ledger entry, not a flag — it is money that
-- has left as far as every other screen is concerned, because it has been committed to a carrier.
-- A cancellation refunds it as a second entry, never by deleting the first, so the trail shows
-- what happened rather than pretending it did not.
create or replace function qvm_new_apps.carrier_reserve_shipment(
  p_carrier_key text,
  p_amount      numeric,
  p_reference   text,
  p_description text default null,
  p_company_id  integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op      boolean := qvm_new_apps.wallet_is_operator();
  v_co      integer := p_company_id;
  v_carrier integer;
  v_wallet  bigint;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الشحنة غير صالحة', 'data', null);
  end if;

  select list_data_id into v_carrier from qvm_new_apps.list_data
   where lower(list_data) = lower(p_carrier_key) limit 1;

  -- The connection has to be live. Charging for a dispatch we cannot actually make would take
  -- money for nothing.
  if not exists (select 1 from qvm_new_apps.carrier_credentials
                  where carrier_id = v_carrier and company_id = v_co and is_active) then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'الاتصال بالناقل غير مفعّل');
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, true);

  -- No p_allow_negative. This is the one caller that genuinely must be refused when the balance
  -- will not cover it, and wallet_charge's refusal message is already the right one.
  return qvm_new_apps.wallet_charge(
    p_wallet_id   => v_wallet,
    p_amount      => -p_amount,
    p_kind        => 'consumption',
    p_description => coalesce(p_description, 'شحنة ' || p_carrier_key),
    p_reference   => p_reference,
    p_source      => 'carrier',
    p_source_id   => lower(p_carrier_key));
end
$$;

-- Giving it back. A separate entry with the opposite sign, never an edit of the original: a
-- ledger that can be rewritten cannot be reconciled, and «this was charged then refunded» is a
-- different fact from «this was never charged».
--
-- Refunds only what was actually taken for that reference, and only once — a second cancellation
-- of the same shipment must not pay the company twice.
create or replace function qvm_new_apps.carrier_refund_shipment(
  p_carrier_key text,
  p_reference   text,
  p_company_id  integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op     boolean := qvm_new_apps.wallet_is_operator();
  v_co     integer := p_company_id;
  v_wallet bigint;
  v_taken  numeric;
  v_given  numeric;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'المحفظة غير موجودة', 'data', null);
  end if;

  select coalesce(sum(-amount) filter (where kind = 'consumption'), 0),
         coalesce(sum(amount)  filter (where kind = 'refund'), 0)
    into v_taken, v_given
    from qvm_new_apps.wallet_entries
   where wallet_id = v_wallet and source = 'carrier'
     and source_id = lower(p_carrier_key) and reference = p_reference;

  if v_taken <= 0 then
    return jsonb_build_object('status', false, 'message', 'لا توجد حركة بهذا المرجع', 'data', null);
  end if;
  if v_given >= v_taken then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تم استرداد هذه الشحنة بالفعل');
  end if;

  return qvm_new_apps.wallet_charge(
    p_wallet_id   => v_wallet,
    p_amount      => v_taken - v_given,
    p_kind        => 'refund',
    p_description => 'استرداد شحنة ملغاة',
    p_reference   => p_reference,
    p_source      => 'carrier',
    p_source_id   => lower(p_carrier_key));
end
$$;

-- What a run of shipments would cost, for the estimator on the pricing tab.
--
-- Named an estimate and returned as one. It multiplies an average by a count, which is not what
-- any individual shipment will cost — the real price comes from the carrier, per shipment, at the
-- moment of dispatch. A screen that showed this as «the amount» would be selling a guess as a
-- quote.
create or replace function qvm_new_apps.carrier_estimate(
  p_carrier_key text,
  p_shipments   integer,
  p_avg_km      numeric,
  p_company_id  integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op   boolean := qvm_new_apps.wallet_is_operator();
  v_co   integer := p_company_id;
  v_base numeric;
  v_perkm numeric;
  v_each numeric;
  v_wallet bigint;
  v_balance numeric := 0;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- The tariff is a row, not a constant, so a rate change is data. These two are what the design
  -- shows as «أساس + لكل كم».
  select amount into v_base  from qvm_new_apps.wallet_rates
   where rate_key = lower(p_carrier_key) || '_base';
  select amount into v_perkm from qvm_new_apps.wallet_rates
   where rate_key = lower(p_carrier_key) || '_per_km';

  v_each := coalesce(v_base, 0) + coalesce(v_perkm, 0) * greatest(coalesce(p_avg_km, 0), 0);

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if v_wallet is not null then
    select coalesce(sum(amount), 0) into v_balance
      from qvm_new_apps.wallet_entries where wallet_id = v_wallet;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'base', v_base, 'per_km', v_perkm,
    'per_shipment', v_each,
    'shipments', greatest(coalesce(p_shipments, 0), 0),
    'estimate', v_each * greatest(coalesce(p_shipments, 0), 0),
    'balance', v_balance,
    -- How much would need topping up to cover the run. Zero when the balance already does.
    'shortfall', greatest(v_each * greatest(coalesce(p_shipments, 0), 0) - v_balance, 0),
    -- Said plainly, so the screen does not have to decide how to caveat it.
    'is_estimate', true));
end
$$;

-- Mrsool's published city tariff, as rows. The real price still comes from their API per
-- shipment; these only drive the estimator.
insert into qvm_new_apps.wallet_rates (rate_key, amount, unit, description) values
  ('mrsool_base',   25, 'SAR',        'Mrsool base fare used by the estimator only'),
  ('mrsool_per_km',  3, 'SAR per km', 'Mrsool per-kilometre rate used by the estimator only')
on conflict (rate_key) do nothing;

revoke all on function qvm_new_apps.carrier_reserve_shipment(text, numeric, text, text, integer) from public;
revoke all on function qvm_new_apps.carrier_refund_shipment(text, text, integer) from public;
revoke all on function qvm_new_apps.carrier_estimate(text, integer, numeric, integer) from public;
grant execute on function qvm_new_apps.carrier_reserve_shipment(text, numeric, text, text, integer),
                          qvm_new_apps.carrier_refund_shipment(text, text, integer),
                          qvm_new_apps.carrier_estimate(text, integer, numeric, integer)
  to authenticated, service_role;
