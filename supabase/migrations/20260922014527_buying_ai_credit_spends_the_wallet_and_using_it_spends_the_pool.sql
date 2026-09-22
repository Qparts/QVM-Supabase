-- Buying AI credit spends the wallet. Using the AI spends the pool.
--
-- Those are two different events and they must be billed once each. Before this, every AI call
-- charged the wallet directly; if that stayed while credit was also bought from the wallet, the
-- same model call would be paid for twice. The trigger is replaced at the bottom of this file.

-- ── Buying ─────────────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.ai_credit_topup(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_amount     numeric default null,
  p_note       text    default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_wallet bigint;
  v_charge jsonb;
  v_entry  bigint;
begin
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الشحن يجب أن تكون أكبر من صفر', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_company_id, p_vendor_id, false);
  if v_wallet is null then
    return jsonb_build_object('status', false, 'message', 'لا توجد محفظة لهذه الجهة', 'data', null);
  end if;
  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه المحفظة', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_company_id, p_vendor_id, true);
  if v_acct is null then
    return jsonb_build_object('status', false, 'message', 'تعذّر تحديد حساب الرصيد', 'data', null);
  end if;

  -- The wallet is charged first and is allowed to refuse. Crediting the pool before knowing the
  -- money left would hand out AI nobody paid for, and `wallet_charge` is the only thing entitled
  -- to decide whether a balance can stand it.
  v_charge := qvm_new_apps.wallet_charge(
    p_wallet_id   => v_wallet,
    p_amount      => -p_amount,
    p_kind        => 'consumption',
    p_description => coalesce(p_note, 'شحن رصيد الذكاء الاصطناعي'),
    p_source      => 'ai_credit');

  if not (v_charge ->> 'status')::boolean then
    return v_charge;
  end if;

  insert into qvm_new_apps.ai_credit_entries
    (account_id, amount, kind, description, wallet_entry_id, created_by)
  values (v_acct, p_amount, 'topup', coalesce(p_note, 'شحن رصيد الذكاء الاصطناعي'),
          (v_charge -> 'data' ->> 'entry_id')::bigint, auth.uid())
  returning entry_id into v_entry;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'account_id', v_acct, 'entry_id', v_entry,
    'balance', qvm_new_apps.ai_credit_balance(v_acct),
    'wallet_balance', v_charge -> 'data' ->> 'balance'));
end
$$;

-- ── The switches ───────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.ai_credit_set_enabled(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_enabled    boolean default true,
  p_reason     text    default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_wallet bigint;
begin
  v_wallet := qvm_new_apps.wallet_of(p_company_id, p_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_company_id, p_vendor_id, true);
  update qvm_new_apps.ai_credit_accounts
     set is_enabled = p_enabled,
         disabled_reason = case when p_enabled then null else nullif(btrim(p_reason), '') end,
         disabled_by     = case when p_enabled then null else auth.uid() end,
         disabled_at     = case when p_enabled then null else now() end,
         updated_at = now()
   where account_id = v_acct;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('account_id', v_acct, 'is_enabled', p_enabled));
end
$$;

-- One party under an organisation's pool, switched on or off by whoever holds that pool.
--
-- NOTE: this version's upsert names an ON CONFLICT target that matches no index, and its
-- membership test is a knot of negations. Both are fixed a minute later in
-- 20260922014627_a_party_switch_upserts_against_the_index_that_actually_exists.sql. Kept because
-- it is what the database ran.
create or replace function qvm_new_apps.ai_credit_set_party(
  p_owner_company_id integer,
  p_owner_vendor_id  integer,
  p_party_company_id integer,
  p_party_vendor_id  integer,
  p_enabled          boolean,
  p_reason           text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_acct   bigint;
  v_wallet bigint;
begin
  if (p_party_company_id is not null) = (p_party_vendor_id is not null) then
    return jsonb_build_object('status', false, 'message', 'حدد جهة واحدة', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_owner_company_id, p_owner_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_owner_company_id, p_owner_vendor_id, true);

  -- Refuse to switch a party that does not draw on this pool. Without this the row would be
  -- written, do nothing, and read on screen as though the AI had been turned off.
  if qvm_new_apps.ai_credit_account_of(p_party_company_id, p_party_vendor_id, false)
     is distinct from v_acct
     and not (p_party_company_id is not null
              and exists (select 1 from qvm_new_apps.vendor_companies vc
                           where vc.company_id = p_owner_company_id))
  then
    if (select o.company_id from qvm_new_apps.ai_credit_owner_of(p_party_company_id, p_party_vendor_id) o)
       is distinct from p_owner_company_id then
      return jsonb_build_object('status', false, 'message', 'هذه الجهة لا تسحب من هذا الرصيد', 'data', null);
    end if;
  end if;

  insert into qvm_new_apps.ai_credit_party_switch
    (account_id, party_company_id, party_vendor_id, is_enabled, reason, set_by, set_at)
  values (v_acct, p_party_company_id, p_party_vendor_id, p_enabled,
          case when p_enabled then null else nullif(btrim(p_reason), '') end, auth.uid(), now())
  on conflict (account_id, coalesce(party_company_id, -1), coalesce(party_vendor_id, -1))
  do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                set_by = excluded.set_by, set_at = excluded.set_at;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('is_enabled', p_enabled));
end
$$;

grant execute on function qvm_new_apps.ai_credit_topup(integer, integer, numeric, text) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_set_enabled(integer, integer, boolean, text) to authenticated, service_role;
grant execute on function qvm_new_apps.ai_credit_set_party(integer, integer, integer, integer, boolean, text) to authenticated, service_role;
