-- A payment recorded by hand needs its evidence attached to it.
--
-- Cash and bank transfers are the receipts Zoho never sees, so this system is the only place
-- they exist — and «somebody typed 5,000 against this invoice» is a claim until the transfer
-- slip is beside it. Without somewhere to put the image it ends up in WhatsApp, which is
-- where the rest of this project has been finding its missing paperwork.
alter table qvm_new_apps.payments
  add column if not exists receipt_url  text,
  add column if not exists receipt_name text;

-- Rewritten to carry the receipt through. Everything else is unchanged, including the refusal
-- to allocate more than was received.
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
    (company_list_data_id, customer_id, paid_on, amount, method, reference, notes,
     receipt_url, receipt_name, source, created_by)
  values (v_company,
          (select c.customer_id from qvm_new_apps.customers c where c.list_data_id = v_company),
          coalesce(nullif(btrim(coalesce(p_data->>'paid_on','')), '')::date, current_date),
          v_amount,
          nullif(btrim(coalesce(p_data->>'method','')), ''),
          nullif(btrim(coalesce(p_data->>'reference','')), ''),
          nullif(btrim(coalesce(p_data->>'notes','')), ''),
          nullif(btrim(coalesce(p_data->>'receipt_url','')), ''),
          nullif(btrim(coalesce(p_data->>'receipt_name','')), ''),
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

-- The statement shows the receipt on the line it belongs to, so «what is this credit» is
-- answered where the question is asked rather than in another screen.
do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.customer_statement(integer,date,date)'::regprocedure);
  v_old text := '             ''method'', pay.method, ''source'', pay.source)';
begin
  -- The GitHub sync replays this file, so the patch has to survive being run twice.
  if position('''receipt_url''' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'payment line not found'; end if;
  execute replace(v_def, v_old,
    '             ''method'', pay.method, ''source'', pay.source,
             ''receipt_url'', pay.receipt_url, ''receipt_name'', pay.receipt_name)');
end
$mig$;
