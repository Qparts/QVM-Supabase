-- Both sides read the same queue.
--
-- One function, not one per persona. The rows an operator sees are every wallet's; the rows an
-- owner sees are its own. Two functions would be two places for that rule to drift apart, and the
-- drift would be invisible until somebody saw a request that was not theirs.
--
-- NOTE: this first version builds the visible set in a temp table, which a STABLE function may
-- not do. It is superseded a few minutes later by
-- 20260922003515_the_topup_queue_reuses_the_permission_rule_instead_of_restating_it.sql, which
-- asks `wallet_can_manage` instead of restating the rule. Kept because it is what the database
-- ran, and a migration history that omits the step that failed is a history you cannot replay.
create or replace function qvm_new_apps.wallet_topup_requests_list(
  p_wallet_id bigint  default null,
  p_status    text    default null,
  p_limit     integer default 50,
  p_offset    integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op    boolean := qvm_new_apps.wallet_is_operator();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows  jsonb;
  v_total integer;
  v_pending integer;
begin
  -- The scope, decided once and used by all three reads below.
  create temp table if not exists _topup_scope (wallet_id bigint) on commit drop;
  delete from _topup_scope;

  if v_op then
    insert into _topup_scope select w.wallet_id from qvm_new_apps.wallets w;
  else
    insert into _topup_scope
    select w.wallet_id from qvm_new_apps.wallets w
     where (w.company_id is not null and exists (
              select 1 from qvm_new_apps.user_companies uc
               where uc.user_id = auth.uid() and uc.company_id = w.company_id))
        or (w.vendor_id is not null and w.vendor_id = qvm_new_apps.current_upload_vendor_id());
  end if;

  select count(*), count(*) filter (where r.status = 'pending')
    into v_total, v_pending
    from qvm_new_apps.wallet_topup_requests r
    join _topup_scope s on s.wallet_id = r.wallet_id
   where (p_wallet_id is null or r.wallet_id = p_wallet_id)
     and (p_status is null or r.status = p_status);

  select coalesce(jsonb_agg(q.row order by q.ord), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'request_id', r.request_id,
               'wallet_id', r.wallet_id,
               'company_id', w.company_id,
               'vendor_id', w.vendor_id,
               -- Whose request it is. The operator's queue is unreadable without it, and it costs
               -- the owner's own list nothing.
               'owner_name', coalesce(nm.name, vn.vendor_name,
                                      case when w.company_id is not null
                                           then 'Company ' || w.company_id
                                           else 'Vendor ' || w.vendor_id end),
               'amount', r.amount, 'currency', r.currency,
               'reference', r.reference, 'note', r.note,
               'receipt_url', r.receipt_url,
               'status', r.status,
               'requested_at', r.requested_at,
               'requested_by', coalesce(nullif(ru.raw_user_meta_data ->> 'full_name', ''), ru.email),
               'decided_at', r.decided_at,
               'decided_by', coalesce(nullif(du.raw_user_meta_data ->> 'full_name', ''), du.email),
               'reason', r.reason,
               'invoice_url', r.invoice_url,
               'invoice_number', r.invoice_number,
               'entry_id', r.entry_id) as row,
             -- Waiting first, then newest. An admin opens this to find what needs them, not to
             -- read history; sorting purely by date buries the queue under everything settled.
             (r.status = 'pending') as ord_pending,
             r.requested_at as ord_at,
             row_number() over (order by (r.status = 'pending') desc, r.requested_at desc) as ord
        from qvm_new_apps.wallet_topup_requests r
        join _topup_scope s on s.wallet_id = r.wallet_id
        join qvm_new_apps.wallets w on w.wallet_id = r.wallet_id
        left join lateral (
          select d.name from qvm_new_apps.client_companies_descriptions d
           where d.company_id = w.company_id and d.name is not null
           order by d.language_id limit 1) nm on true
        left join lateral (
          select v.vendor_name from qvm_new_apps.vendors v
           where v.vendor_id = w.vendor_id limit 1) vn on true
        left join auth.users ru on ru.id = r.requested_by
        left join auth.users du on du.id = r.decided_by
       where (p_wallet_id is null or r.wallet_id = p_wallet_id)
         and (p_status is null or r.status = p_status)
       order by (r.status = 'pending') desc, r.requested_at desc
       limit v_limit offset greatest(coalesce(p_offset, 0), 0)) q;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'pending', v_pending,
    'side', case when v_op then 'operator' else 'owner' end));
end
$$;

grant execute on function qvm_new_apps.wallet_topup_requests_list(bigint, text, integer, integer)
  to authenticated, service_role;
