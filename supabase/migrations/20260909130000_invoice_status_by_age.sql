-- Invoice status, decided by age and by whether money actually arrived.
--
-- Two things were wrong with the old rule.
--
-- «Paid» was `total - paid <= 0`, which a zero-total invoice satisfies with nobody having paid
-- anything: 0 - 0 <= 0. So an invoice that had never been billed, let alone settled, sat on the
-- list wearing a green Paid badge. Paid now means a real amount was owed and at least that much
-- was received.
--
-- «Overdue» was `due_date < current_date`. Every due date in this data equals its issue date, so
-- every invoice was overdue the day it was written and the column carried no information. The
-- rule is now the one the business actually works to: an invoice older than ten days is overdue,
-- and under that it is simply not due yet.
create or replace function qvm_new_apps.invoices_list(
  p_status text default null,
  p_company integer default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_company integer;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb; v_total bigint; v_sum jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- A customer's own users see their own company and nothing else. Decided here, not by a
  -- parameter, so it cannot be widened by whoever is calling.
  select u.user_company into v_company from qvm_new_apps.user_data u where u.user_id = v_uid;
  if not v_team and v_company is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with scoped as (
    select i.*, p.company_id, p.company_name, p.customer_id,
           coalesce(i.total, 0) - coalesce(i.paid_amount, 0) as balance,
           case
             -- Settled, and settled by money rather than by arithmetic.
             when coalesce(i.total, 0) > 0
              and coalesce(i.paid_amount, 0) >= coalesce(i.total, 0) then 'paid'
             -- Nothing is owed on it, so there is nothing to chase. An invoice carrying no
             -- amount yet is unbilled, not late, and calling it overdue in ten days' time
             -- would send somebody after zero riyals.
             when coalesce(i.total, 0) - coalesce(i.paid_amount, 0) <= 0 then 'pending'
             when current_date - i.created_at::date > 10 then 'overdue'
             else 'pending'
           end as pay_status
      from qvm_new_apps.invoices i
      cross join lateral qvm_new_apps.invoice_party(i.invoice_id) p
     where (v_team or p.company_id = v_company)
       and (p_company is null or p.company_id = p_company)
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'invoice_id', s.invoice_id, 'number', s.invoice_number, 'url', s.invoice_url,
        'order_id', s.confirmed_order_id, 'company', s.company_name, 'company_id', s.company_id,
        'customer_id', s.customer_id,
        'subtotal', s.subtotal, 'vat', s.vat, 'total', s.total,
        'paid', s.paid_amount, 'balance', s.balance, 'currency', s.currency,
        'amounts_source', s.amounts_source,
        'zoho_status', s.zoho_status, 'due_date', s.due_date, 'paid_at', s.paid_at,
        'pay_status', s.pay_status, 'created_at', s.created_at)
        order by s.created_at desc)
      from scoped s
     where (p_status is null or s.pay_status = p_status)
       and (v_q is null or coalesce(s.invoice_number,'') ilike '%'||v_q||'%'
                        or coalesce(s.company_name,'') ilike '%'||v_q||'%'
                        or coalesce(s.confirmed_order_id::text,'') ilike '%'||v_q||'%')
     limit greatest(p_limit,1) offset greatest(p_offset,0)), '[]'::jsonb),
    (select count(*) from scoped s
      where (p_status is null or s.pay_status = p_status)
        and (v_q is null or coalesce(s.invoice_number,'') ilike '%'||v_q||'%'
                         or coalesce(s.company_name,'') ilike '%'||v_q||'%'
                         or coalesce(s.confirmed_order_id::text,'') ilike '%'||v_q||'%')),
    -- The counters at the top count what this reader can see, on the whole scope and not
    -- only the page in front of them.
    (select jsonb_build_object(
       'paid',    count(*) filter (where pay_status = 'paid'),
       'pending', count(*) filter (where pay_status = 'pending'),
       'overdue', count(*) filter (where pay_status = 'overdue'),
       'outstanding', coalesce(sum(balance) filter (where pay_status <> 'paid'), 0))
       from scoped)
  into v_rows, v_total, v_sum;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counters', v_sum,
    'role', case when v_team then 'team' else 'customer' end,
    'companies', case when v_team then coalesce((
      select jsonb_agg(distinct jsonb_build_object('id', d.list_data_id, 'name', d.list_data))
        from qvm_new_apps.list_data d where d.list_id = 1), '[]'::jsonb) else '[]'::jsonb end));
end
$function$;
