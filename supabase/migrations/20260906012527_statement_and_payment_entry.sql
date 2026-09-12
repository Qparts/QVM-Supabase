-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- S-7 — «كشف الحساب والمدفوعات».
--
-- One customer, everything that moved their balance, in date order with a running total, plus
-- the aging buckets that decide whether somebody chases them. The running balance is computed
-- here rather than stored: a stored balance and the rows it comes from disagree the first time
-- anybody edits one of them.
create or replace function qvm_new_apps.customer_statement(
  p_company integer default null,
  p_from date default null,
  p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_own integer;
  v_company integer;
  v_lines jsonb; v_open numeric;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select u.user_company into v_own from qvm_new_apps.user_data u where u.user_id = v_uid;

  -- A customer's users read their own company whatever they ask for.
  v_company := case when v_team then coalesce(p_company, v_own) else v_own end;
  if v_company is null then
    return jsonb_build_object('status', false,
      'message', 'اختر العميل', 'data', null);
  end if;

  -- Everything before the window is one opening figure rather than rows nobody asked for.
  select coalesce(sum(x.amount), 0) into v_open from (
    select coalesce(i.total, 0) as amount
      from qvm_new_apps.invoices i
      cross join lateral qvm_new_apps.invoice_party(i.invoice_id) p
     where p.company_id = v_company
       and (p_from is null or i.created_at::date < p_from)
    union all
    select -pay.amount
      from qvm_new_apps.payments pay
     where pay.company_list_data_id = v_company
       and (p_from is null or pay.paid_on < p_from)
  ) x;

  select coalesce(jsonb_agg(l order by l->>'date', l->>'kind'), '[]'::jsonb) into v_lines
  from (
    select jsonb_build_object(
             'kind', 'invoice', 'date', i.created_at::date, 'ref', i.invoice_number,
             'order_id', i.confirmed_order_id, 'debit', coalesce(i.total, 0), 'credit', 0,
             'due_date', i.due_date, 'url', i.invoice_url) as l
      from qvm_new_apps.invoices i
      cross join lateral qvm_new_apps.invoice_party(i.invoice_id) p
     where p.company_id = v_company
       and (p_from is null or i.created_at::date >= p_from)
       and (p_to is null or i.created_at::date <= p_to)
    union all
    select jsonb_build_object(
             'kind', 'payment', 'date', pay.paid_on, 'ref', coalesce(pay.reference, pay.zoho_payment_id),
             'order_id', null, 'debit', 0, 'credit', pay.amount,
             'method', pay.method, 'source', pay.source)
      from qvm_new_apps.payments pay
     where pay.company_list_data_id = v_company
       and (p_from is null or pay.paid_on >= p_from)
       and (p_to is null or pay.paid_on <= p_to)
    union all
    -- A credit note reduces what is owed. It carries no amount of its own in this schema, so
    -- it is listed for the trail and valued at zero rather than guessed at.
    select jsonb_build_object(
             'kind', 'credit_note', 'date', cn.created_at::date, 'ref', cn.creditnote_number,
             'order_id', cn.confirmed_order_id, 'debit', 0, 'credit', 0, 'url', cn.creditnote_url)
      from qvm_new_apps.creditnotes cn
      join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = cn.confirmed_order_id
      join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
      join qvm_new_apps.user_data u on u.user_id = q.service_advisor
     where u.user_company = v_company
       and (p_from is null or cn.created_at::date >= p_from)
       and (p_to is null or cn.created_at::date <= p_to)
  ) rows;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'company_id', v_company,
    'company', (select list_data from qvm_new_apps.list_data where list_data_id = v_company),
    'opening_balance', v_open,
    'lines', v_lines,
    'credit_limit', (select c.credit_limit from qvm_new_apps.customers c where c.list_data_id = v_company),
    -- Aging on the unpaid balance, by how long each invoice has been past its due date.
    'aging', coalesce((
      select jsonb_build_object(
        'current',  coalesce(sum(b) filter (where d <= 0), 0),
        'd1_30',    coalesce(sum(b) filter (where d between 1 and 30), 0),
        'd31_60',   coalesce(sum(b) filter (where d between 31 and 60), 0),
        'd61_90',   coalesce(sum(b) filter (where d between 61 and 90), 0),
        'd90_plus', coalesce(sum(b) filter (where d > 90), 0))
      from (
        select coalesce(i.total,0) - coalesce(i.paid_amount,0) as b,
               current_date - coalesce(i.due_date, i.created_at::date) as d
          from qvm_new_apps.invoices i
          cross join lateral qvm_new_apps.invoice_party(i.invoice_id) p
         where p.company_id = v_company
           and coalesce(i.total,0) - coalesce(i.paid_amount,0) > 0) a), '{}'::jsonb),
    'companies', case when v_team then coalesce((
      select jsonb_agg(jsonb_build_object('id', d.list_data_id, 'name', d.list_data) order by d.list_data)
        from qvm_new_apps.list_data d where d.list_id = 1), '[]'::jsonb) else '[]'::jsonb end));
end
$function$;

-- Recording a payment by hand — cash and bank transfers, the half Zoho never sees
-- (Open Decision 4). Allocating it to invoices is what makes it show against a balance.
create or replace function qvm_new_apps.payment_record(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_company integer := nullif(p_data->>'company_id','')::integer;
  v_amount numeric := nullif(btrim(coalesce(p_data->>'amount','')), '')::numeric;
  v_id bigint; r jsonb; v_alloc numeric := 0;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_company is null then
    return jsonb_build_object('status', false, 'message', 'اختر العميل', 'data', null);
  end if;
  if v_amount is null or v_amount <= 0 then
    return jsonb_build_object('status', false, 'message', 'المبلغ مطلوب', 'data', null);
  end if;

  insert into qvm_new_apps.payments
    (company_list_data_id, customer_id, paid_on, amount, method, reference, notes, source, created_by)
  values (v_company,
          (select c.customer_id from qvm_new_apps.customers c where c.list_data_id = v_company),
          coalesce(nullif(btrim(coalesce(p_data->>'paid_on','')), '')::date, current_date),
          v_amount,
          nullif(btrim(coalesce(p_data->>'method','')), ''),
          nullif(btrim(coalesce(p_data->>'reference','')), ''),
          nullif(btrim(coalesce(p_data->>'notes','')), ''),
          'manual', auth.uid())
  returning payment_id into v_id;

  for r in select * from jsonb_array_elements(coalesce(p_data->'allocations', '[]'::jsonb)) loop
    insert into qvm_new_apps.payment_allocations (payment_id, invoice_id, amount)
    values (v_id, (r->>'invoice_id')::bigint, (r->>'amount')::numeric);
    perform qvm_new_apps.invoice_refresh_paid((r->>'invoice_id')::bigint);
    v_alloc := v_alloc + (r->>'amount')::numeric;
  end loop;

  -- Allocating more than was received would show invoices settled with money nobody paid.
  if v_alloc > v_amount then
    raise exception 'المخصَّص للفواتير (%) أكبر من مبلغ الدفعة (%)', v_alloc, v_amount;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('payment_id', v_id, 'allocated', v_alloc, 'unallocated', v_amount - v_alloc));
end
$function$;

revoke all on function qvm_new_apps.customer_statement(integer, date, date) from public;
revoke all on function qvm_new_apps.payment_record(jsonb) from public;
grant execute on function qvm_new_apps.customer_statement(integer, date, date) to authenticated;
grant execute on function qvm_new_apps.payment_record(jsonb) to authenticated;
