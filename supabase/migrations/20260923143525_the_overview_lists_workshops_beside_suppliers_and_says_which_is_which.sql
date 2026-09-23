-- The overview lists workshops beside suppliers, and says which is which.
--
-- Three kinds of party now draw on one pool, and «abdullah» tells you nothing about whether it
-- is a supplier or a workshop. The kind travels with every row so the screen can label it rather
-- than guess from the name.
--
-- Workshops come from `workshop_companies`, the same link the Companies & Workshops page draws,
-- so the two screens cannot disagree about who belongs to whom. Listed even when they have never
-- spent a point — a workshop you cannot see is a workshop you cannot cap before it costs you
-- anything, which is the whole point of having the column.
drop function if exists qvm_new_apps.ai_credit_set_party(
  integer, integer, integer, integer, boolean, text, boolean, numeric);

create or replace function qvm_new_apps.ai_credit_set_party(
  p_owner_company_id integer,
  p_owner_vendor_id  integer,
  p_party_company_id integer,
  p_party_vendor_id  integer,
  p_enabled          boolean,
  p_reason           text    default null,
  p_set_limit        boolean default false,
  p_monthly_limit    numeric default null,
  p_party_workshop_id bigint default null)
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
  v_kinds    integer := (p_party_company_id is not null)::int
                      + (p_party_vendor_id is not null)::int
                      + (p_party_workshop_id is not null)::int;
begin
  if v_kinds <> 1 then
    return jsonb_build_object('status', false, 'message', 'حدد جهة واحدة', 'data', null);
  end if;
  if p_set_limit and p_monthly_limit is not null and p_monthly_limit < 0 then
    return jsonb_build_object('status', false, 'message', 'الحد لا يمكن أن يكون سالبًا', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(p_owner_company_id, p_owner_vendor_id, false);
  if v_wallet is null or not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه الجهة', 'data', null);
  end if;

  -- Does this party draw on this pool? Asked of whichever function owns the answer for its kind.
  if p_party_workshop_id is not null then
    v_owner_co := qvm_new_apps.ai_workshop_company(p_party_workshop_id);
    v_owner_vn := null;
  else
    select o.company_id, o.vendor_id into v_owner_co, v_owner_vn
      from qvm_new_apps.ai_credit_owner_of(p_party_company_id, p_party_vendor_id) o;
  end if;

  if v_owner_co is distinct from p_owner_company_id
     or v_owner_vn is distinct from p_owner_vendor_id then
    return jsonb_build_object('status', false, 'message', 'هذه الجهة لا تسحب من هذا الرصيد', 'data', null);
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(p_owner_company_id, p_owner_vendor_id, true);

  -- One branch per partial index, because that is how many indexes there are.
  if p_party_company_id is not null then
    insert into qvm_new_apps.ai_credit_party_policy
      (account_id, party_company_id, party_vendor_id, party_workshop_id,
       is_enabled, reason, monthly_point_limit, set_by, set_at)
    values (v_acct, p_party_company_id, null, null, p_enabled, v_reason,
            case when p_set_limit then p_monthly_limit else null end, auth.uid(), now())
    on conflict (account_id, party_company_id) where party_company_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  monthly_point_limit = case when p_set_limit then excluded.monthly_point_limit
                                             else qvm_new_apps.ai_credit_party_policy.monthly_point_limit end,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  elsif p_party_vendor_id is not null then
    insert into qvm_new_apps.ai_credit_party_policy
      (account_id, party_company_id, party_vendor_id, party_workshop_id,
       is_enabled, reason, monthly_point_limit, set_by, set_at)
    values (v_acct, null, p_party_vendor_id, null, p_enabled, v_reason,
            case when p_set_limit then p_monthly_limit else null end, auth.uid(), now())
    on conflict (account_id, party_vendor_id) where party_vendor_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  monthly_point_limit = case when p_set_limit then excluded.monthly_point_limit
                                             else qvm_new_apps.ai_credit_party_policy.monthly_point_limit end,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  else
    insert into qvm_new_apps.ai_credit_party_policy
      (account_id, party_company_id, party_vendor_id, party_workshop_id,
       is_enabled, reason, monthly_point_limit, set_by, set_at)
    values (v_acct, null, null, p_party_workshop_id, p_enabled, v_reason,
            case when p_set_limit then p_monthly_limit else null end, auth.uid(), now())
    on conflict (account_id, party_workshop_id) where party_workshop_id is not null
    do update set is_enabled = excluded.is_enabled, reason = excluded.reason,
                  monthly_point_limit = case when p_set_limit then excluded.monthly_point_limit
                                             else qvm_new_apps.ai_credit_party_policy.monthly_point_limit end,
                  set_by = excluded.set_by, set_at = excluded.set_at;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('account_id', v_acct, 'is_enabled', p_enabled));
end
$$;

grant execute on function qvm_new_apps.ai_credit_set_party(
  integer, integer, integer, integer, boolean, text, boolean, numeric, bigint)
  to authenticated, service_role;
