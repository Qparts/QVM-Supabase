-- Resolving a wallet. Created on first sight rather than at signup, so an owner who never spends
-- never has a row, and nothing has to be backfilled when a new company appears.
create or replace function qvm_new_apps.wallet_of(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_create     boolean default true)
returns bigint
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_id bigint;
begin
  if num_nonnulls(p_company_id, p_vendor_id) <> 1 then
    return null;
  end if;

  select wallet_id into v_id from qvm_new_apps.wallets
   where (p_company_id is not null and company_id = p_company_id)
      or (p_vendor_id  is not null and vendor_id  = p_vendor_id);
  if v_id is not null or not p_create then
    return v_id;
  end if;

  -- ON CONFLICT rather than «check then insert»: two first-ever charges arriving together would
  -- both find nothing and both insert, and the unique index is the only thing that can decide.
  insert into qvm_new_apps.wallets (company_id, vendor_id, created_by)
  values (p_company_id, p_vendor_id, auth.uid())
  on conflict do nothing
  returning wallet_id into v_id;

  if v_id is null then
    select wallet_id into v_id from qvm_new_apps.wallets
     where (p_company_id is not null and company_id = p_company_id)
        or (p_vendor_id  is not null and vendor_id  = p_vendor_id);
  end if;
  return v_id;
end
$$;

-- ── The only door ──────────────────────────────────────────────────────────────────────────────
-- Every movement of money goes through here: top-ups positive, everything else negative. One
-- function rather than one per reason, because the thing that has to be right — the balance
-- cannot go below zero and cannot be spent twice — is the same regardless of what the money was
-- for, and repeating it per caller is repeating the chance to get it wrong.
--
-- The lock is the whole point. Two AI calls finishing at the same instant both read a balance of
-- 10, both decide 8 is affordable, and both insert: the wallet ends at -6 having authorised 16.
-- SELECT … FOR UPDATE on the wallet row serialises them, so the second one reads the balance the
-- first one left and is refused. Locking the wallet and not the entries is deliberate — the
-- entries are what we are adding to, the wallet is the thing being contended for.
--
-- Overdraft is refused by default and allowed only to the Qparts team, for the case the design
-- shows as «مصروف تشغيلي»: a cost that has already been incurred and has to be recorded whether
-- or not the balance covers it. Refusing to record a fact does not make it untrue.
create or replace function qvm_new_apps.wallet_charge(
  p_wallet_id      bigint,
  p_amount         numeric,
  p_kind           text,
  p_description    text default null,
  p_reference      text default null,
  p_source         text default null,
  p_source_id      text default null,
  p_expires_on     date default null,
  p_invoice_url    text default null,
  p_allow_negative boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_balance numeric;
  v_after   numeric;
  v_id      bigint;
  v_locked  bigint;
begin
  if coalesce(p_amount, 0) = 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الحركة لا يمكن أن تكون صفر', 'data', null);
  end if;
  if p_kind is null or p_kind not in
     ('topup','consumption','subscription','operational','refund','adjustment') then
    return jsonb_build_object('status', false, 'message', 'نوع حركة غير معروف', 'data', null);
  end if;

  -- Nothing below this line may read the balance without holding this.
  select wallet_id into v_locked from qvm_new_apps.wallets
   where wallet_id = p_wallet_id for update;
  if v_locked is null then
    return jsonb_build_object('status', false, 'message', 'المحفظة غير موجودة', 'data', null);
  end if;

  select coalesce(sum(amount), 0) into v_balance
    from qvm_new_apps.wallet_entries where wallet_id = p_wallet_id;
  v_after := v_balance + p_amount;

  if v_after < 0 and not (p_allow_negative and qvm_new_apps.is_qparts_team()) then
    return jsonb_build_object('status', false, 'data',
      jsonb_build_object('balance', v_balance, 'required', abs(p_amount)),
      'message', 'الرصيد غير كافٍ');
  end if;

  insert into qvm_new_apps.wallet_entries
    (wallet_id, amount, balance_after, kind, source, source_id, reference, description,
     expires_on, invoice_url, created_by)
  values (p_wallet_id, p_amount, v_after, p_kind, p_source, p_source_id,
          nullif(btrim(coalesce(p_reference,'')), ''),
          nullif(btrim(coalesce(p_description,'')), ''),
          p_expires_on, p_invoice_url, auth.uid())
  returning entry_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'entry_id', v_id, 'balance', v_after,
    -- The caller can warn without re-reading the wallet.
    'low', (select w.low_balance_threshold is not null and v_after < w.low_balance_threshold
              from qvm_new_apps.wallets w where w.wallet_id = p_wallet_id)));
end
$$;

-- Can this be afforded? For callers that want to check BEFORE doing the expensive thing.
--
-- Deliberately not a reservation: it answers for the instant it is asked and the money can be
-- gone by the time the work finishes. wallet_charge is still the thing that decides. A function
-- that looked like a hold without being one would be worse than none.
create or replace function qvm_new_apps.wallet_can_spend(p_wallet_id bigint, p_amount numeric)
returns boolean
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select coalesce((select sum(amount) from qvm_new_apps.wallet_entries
                    where wallet_id = p_wallet_id), 0) >= abs(coalesce(p_amount, 0));
$$;

-- ── The drift detector ─────────────────────────────────────────────────────────────────────────
-- balance_after is stored, which is only safe while every write holds the lock above. This walks
-- each wallet's entries in order, re-adds them, and reports any row whose stored figure disagrees.
-- It should always return nothing; the point is that if it ever does not, somebody finds out.
create or replace function qvm_new_apps.wallet_verify()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_bad jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'wallet_id', w, 'entry_id', e, 'stored', stored, 'derived', derived)), '[]'::jsonb)
    into v_bad
    from (select wallet_id as w, entry_id as e, balance_after as stored,
                 sum(amount) over (partition by wallet_id order by entry_id
                                   rows between unbounded preceding and current row) as derived
            from qvm_new_apps.wallet_entries) k
   where stored is distinct from derived;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'mismatches', v_bad, 'clean', jsonb_array_length(v_bad) = 0));
end
$$;

revoke all on function qvm_new_apps.wallet_of(integer, integer, boolean) from public;
revoke all on function qvm_new_apps.wallet_charge(bigint, numeric, text, text, text, text, text, date, text, boolean) from public;
revoke all on function qvm_new_apps.wallet_can_spend(bigint, numeric) from public;
revoke all on function qvm_new_apps.wallet_verify() from public;
grant execute on function qvm_new_apps.wallet_can_spend(bigint, numeric),
                          qvm_new_apps.wallet_verify()
  to authenticated, service_role;
