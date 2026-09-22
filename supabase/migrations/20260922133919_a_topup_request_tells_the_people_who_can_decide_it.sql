-- A top-up request tells the people who can decide it.
--
-- The queue existed but nothing announced it, so an organisation could transfer the money, attach
-- the receipt, and wait for somebody on the Qparts side to happen to open the wallet page. That
-- is the exact failure the whole feature was written to end — «the money moves at the bank and
-- nothing moves here until somebody notices» — solved for the owner and left in place for us.
--
-- Recipients are defined by the same rule that decides who may act: `wallet_is_operator()` is a
-- test on the current user, so the set is spelled out here from the same three conditions. If
-- those ever diverge, somebody gets told about work they cannot do — which is worse than silence,
-- because they will assume it is handled.
create or replace function qvm_new_apps.wallet_operator_ids()
returns setof uuid
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select u.user_id
    from qvm_new_apps.user_data u
   where (u.user_role in (172, 173, 269) or u.user_type = 185)
     and not exists (select 1 from qvm_new_apps.user_companies uc where uc.user_id = u.user_id)
     and u.user_vendor is null;
$$;

-- How many are waiting on this caller. Scoped by the same permission rule as the list, so an
-- owner's badge counts only their own requests and an operator's counts everybody's.
create or replace function qvm_new_apps.wallet_topup_pending_count()
returns integer
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select count(*)::int
    from qvm_new_apps.wallet_topup_requests r
   where r.status = 'pending'
     and qvm_new_apps.wallet_can_manage(r.wallet_id);
$$;

-- Raised on creation, in the same transaction as the request. A notification written afterwards
-- by something else is a notification that can be missing while the request exists.
create or replace function qvm_new_apps.wallet_topup_notify()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_owner text;
begin
  select coalesce(nm.name, vn.vendor_name,
                  case when w.company_id is not null then 'Company ' || w.company_id
                       else 'Vendor ' || w.vendor_id end)
    into v_owner
    from qvm_new_apps.wallets w
    left join lateral (select d.name from qvm_new_apps.client_companies_descriptions d
                        where d.company_id = w.company_id and d.name is not null
                        order by d.language_id limit 1) nm on true
    left join lateral (select v.vendor_name from qvm_new_apps.vendors v
                        where v.vendor_id = w.vendor_id limit 1) vn on true
   where w.wallet_id = new.wallet_id;

  insert into qvm_new_apps.notifications
    (title, body, data, target_type, target_user_id, created_by)
  select 'QVM',
         -- The amount is in the body on purpose: a decision-maker triaging ten of these wants to
         -- know which one is 50,000 riyals without opening any of them.
         'طلب شحن رصيد من ' || coalesce(v_owner, '—') || ' بمبلغ ' ||
           trim(to_char(new.amount, 'FM999999990.00')) || ' ' || new.currency,
         jsonb_build_object('nav_target', 'wallet', 'topup_request_id', new.request_id,
                            'amount', new.amount, 'owner', v_owner),
         'user', op, new.requested_by
    from qvm_new_apps.wallet_operator_ids() op;

  return new;
exception when others then
  -- The request is the thing that matters. A notification that could not be written must not
  -- take the request down with it — that would be an organisation told its transfer failed when
  -- the only thing that failed was telling us about it.
  raise warning 'wallet: could not notify for topup request %: %', new.request_id, sqlerrm;
  return new;
end
$$;

drop trigger if exists wallet_topup_notify_trg on qvm_new_apps.wallet_topup_requests;
create trigger wallet_topup_notify_trg
  after insert on qvm_new_apps.wallet_topup_requests
  for each row execute function qvm_new_apps.wallet_topup_notify();

-- And the other direction: the organisation learns the verdict without watching the page.
create or replace function qvm_new_apps.wallet_topup_notify_decision()
returns trigger
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
begin
  if new.status = old.status or new.status = 'pending' then return new; end if;
  if new.requested_by is null then return new; end if;

  insert into qvm_new_apps.notifications
    (title, body, data, target_type, target_user_id, created_by)
  values ('QVM',
          case new.status
            when 'approved' then 'تمت الموافقة على طلب الشحن وإضافة ' ||
                                 trim(to_char(new.amount, 'FM999999990.00')) || ' ' ||
                                 new.currency || ' إلى المحفظة'
            -- The reason travels with the refusal. Without it the notification sends somebody to
            -- go and look for why, which is the same as not telling them.
            else 'تم رفض طلب الشحن: ' || coalesce(new.reason, '—')
          end,
          jsonb_build_object('nav_target', 'wallet', 'topup_request_id', new.request_id,
                             'status', new.status),
          'user', new.requested_by, new.decided_by);
  return new;
exception when others then
  raise warning 'wallet: could not notify decision on topup request %: %', new.request_id, sqlerrm;
  return new;
end
$$;

drop trigger if exists wallet_topup_notify_decision_trg on qvm_new_apps.wallet_topup_requests;
create trigger wallet_topup_notify_decision_trg
  after update of status on qvm_new_apps.wallet_topup_requests
  for each row execute function qvm_new_apps.wallet_topup_notify_decision();

grant execute on function qvm_new_apps.wallet_operator_ids() to authenticated, service_role;
grant execute on function qvm_new_apps.wallet_topup_pending_count() to authenticated, service_role;
