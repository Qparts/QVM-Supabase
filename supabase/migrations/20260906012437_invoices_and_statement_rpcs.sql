-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Who a given invoice belongs to. Orders reach a client through the advisor's company
-- (list 1) today, and only some companies have a `customers` row yet, so both are returned
-- and the caller is never left guessing which one it has.
create or replace function qvm_new_apps.invoice_party(p_invoice_id bigint)
returns table (company_id integer, company_name text, customer_id bigint)
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $fn$
  select u.user_company, ld.list_data, c.customer_id
    from qvm_new_apps.invoices i
    join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = i.confirmed_order_id
    join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
    left join qvm_new_apps.user_data u on u.user_id = q.service_advisor
    left join qvm_new_apps.list_data ld on ld.list_data_id = u.user_company
    left join qvm_new_apps.customers c on c.list_data_id = u.user_company
   where i.invoice_id = p_invoice_id;
$fn$;

-- S-6 — «الفواتير».
create or replace function qvm_new_apps.invoices_list(
  p_status text default null,      -- paid | pending | overdue
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
             when coalesce(i.total, 0) > 0 and coalesce(i.paid_amount, 0) >= i.total then 'paid'
             when i.due_date is not null and i.due_date < current_date then 'overdue'
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

revoke all on function qvm_new_apps.invoices_list(text, integer, text, integer, integer) from public;
revoke all on function qvm_new_apps.invoice_party(bigint) from public;
grant execute on function qvm_new_apps.invoices_list(text, integer, text, integer, integer) to authenticated;
grant execute on function qvm_new_apps.invoice_party(bigint) to authenticated, service_role;
