-- A party switch upserts against the index that actually exists.
--
-- Two bugs in the first version, one of them the trap this codebase has now hit three times.
--
-- 1. `on conflict (account_id, coalesce(party_company_id, -1), coalesce(party_vendor_id, -1))`
--    matches no index. The uniqueness is two *partial* indexes — one per kind of party — because
--    the unused column is null and NULL never collides with NULL. An ON CONFLICT target has to
--    name a real index, so it names one of the two, chosen by which kind of party this is.
--
-- 2. The membership test was a knot of negations that happened to reject the one case it was
--    handed. Replaced with the plain question: does this party draw on this pool? That is what
--    `ai_credit_owner_of` already answers, so it is asked once and compared directly.
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
  v_acct     bigint;
  v_wallet   bigint;
  v_owner_co integer;
  v_owner_vn integer;
  v_reason   text := case when p_enabled then null else nullif(btrim(p_reason), '') end;
begin
  if (p_party_company_id is not null) = (p_party_vendor_id is not null) then
    return jsonb_build_object('status', false, 'message', 'حدد جهة واحدة', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_owner_company_id, p_owner_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;

  -- Does this party actually draw on this pool? One question, asked of the function that owns
  -- the answer. A switch written against a pool the party never touches would save, show as off
  -- on screen, and change nothing at all.
  select o.company_id, o.vendor_id into v_owner_co, v_owner_vn
    from qvm_new_apps.ai_credit_owner_of(p_party_company_id, p_party_vendor_id) o;

  if v_owner_co is distinct from p_owner_company_id
     or v_owner_vn is distinct from p_owner_vendor_id then
    return jsonb_build_object('status', false, 'message', 'هذه الجهة لا تسحب من هذا الرصيد', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_owner_company_id, p_owner_vendor_id, true);

  -- One branch per partial index, because that is how many indexes there are.
  if p_party_company_id is not null then
    insert into qvm_new_apps.ai_credit_party_switch
      (account_id, party_company_id, party_vendor_id, is_enabled, reason, set_by, set_at)
    values (v_acct, p_party_company_id, null, p_enabled, v_reason, auth.uid(), now())
    on conflict (account_id, party_company_id) where party_company_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  else
    insert into qvm_new_apps.ai_credit_party_switch
      (account_id, party_company_id, party_vendor_id, is_enabled, reason, set_by, set_at)
    values (v_acct, null, p_party_vendor_id, p_enabled, v_reason, auth.uid(), now())
    on conflict (account_id, party_vendor_id) where party_vendor_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('account_id', v_acct, 'is_enabled', p_enabled));
end
$$;

grant execute on function qvm_new_apps.ai_credit_set_party(integer, integer, integer, integer, boolean, text)
  to authenticated, service_role;
