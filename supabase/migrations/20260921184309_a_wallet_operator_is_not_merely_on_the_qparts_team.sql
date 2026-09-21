-- Who operates wallets is a narrower question than who is on the Qparts team.
--
-- is_qparts_team() is true for any user_type = 185, and on this platform that includes roles that
-- belong to one customer — Company Admin (316) and Procurement User (271) are both 185, and both
-- are attached to a single company. Built on that test, the wallet let a customer's own admin open,
-- top up and audit every OTHER company's balance. That is not a rough edge, it is a customer
-- reading another customer's money.
--
-- The narrower test uses the fact that already distinguishes them rather than a list of role ids,
-- which are minted per environment and drift: a user attached to a company acts for that company;
-- a Qparts user attached to none acts for the platform.
--
-- Deliberately biased to the narrow side. If the buying desk finds it cannot reach a supplier's
-- wallet, that is a complaint someone makes out loud on the first day. The other way round is
-- silent, and the thing it leaks is money.
create or replace function qvm_new_apps.wallet_is_operator()
returns boolean
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select qvm_new_apps.is_qparts_team()
     and not exists (select 1 from qvm_new_apps.user_companies uc
                      where uc.user_id = auth.uid())
     and qvm_new_apps.current_upload_vendor_id() is null;
$$;

comment on function qvm_new_apps.wallet_is_operator() is
  'Platform-wide wallet access. Narrower than is_qparts_team(), which is true for Company Admin '
  'and Procurement User — both bound to a single customer.';

-- Every wallet function that asked «are you on the team» now asks «do you operate wallets».
do $do$
declare
  v_names text[] := array['wallet_can_manage','wallet_get','wallet_topup',
                          'wallet_record_expense','wallet_verify','wallet_subscriptions_renew_due'];
  v_fn    text;
  v_oid   oid;
  v_def   text;
  v_hits  integer;
begin
  foreach v_fn in array v_names loop
    select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'qvm_new_apps' and p.proname = v_fn;
    v_def := pg_get_functiondef(v_oid);

    v_hits := (length(v_def) - length(replace(v_def, 'qvm_new_apps.is_qparts_team()', '')))
              / length('qvm_new_apps.is_qparts_team()');
    if v_hits < 1 then
      raise exception '%: expected at least one is_qparts_team() call, found %', v_fn, v_hits;
    end if;

    execute replace(v_def, 'qvm_new_apps.is_qparts_team()', 'qvm_new_apps.wallet_is_operator()');
  end loop;
end
$do$;

-- wallet_charge keeps is_qparts_team() in ONE place on purpose: the overdraft escape hatch. It is
-- reached from the AI trigger, which runs as the definer and has no session user at all, so tying
-- it to wallet_is_operator() would make an unattended charge fail differently from an attended
-- one. The overdraft path is also already gated by its caller — only wallet_record_expense and the
-- trigger pass p_allow_negative.

revoke all on function qvm_new_apps.wallet_is_operator() from public;
grant execute on function qvm_new_apps.wallet_is_operator() to authenticated, service_role;
