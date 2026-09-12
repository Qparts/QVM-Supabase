-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Corrects the previous version, which read `delivery_notes` at face value and produced
-- invoices whose VAT was 15.00 and whose gross equalled their net.
--
-- The two columns do not mean what they are called: `vat` holds the *rate* (15), and
-- `total_price_including_vat` is populated with the net, not the gross. Only
-- `total_price_before_vat` can be taken as written. So the net is summed and the tax is
-- derived from the rate on the note, which is also what the printed delivery note does.
create or replace function qvm_new_apps.invoice_compute_amounts(p_invoice_id bigint)
returns void
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_sub numeric; v_rate numeric; v_vat numeric; v_total numeric;
begin
  select sum(qvm_new_apps.num_or_null(dn.total_price_before_vat)),
         max(qvm_new_apps.num_or_null(dn.vat))
    into v_sub, v_rate
    from qvm_new_apps.invoice_items ii
    join qvm_new_apps.delivery_notes dn on dn.confirmed_item_id = ii.confirmed_item_id
   where ii.invoice_id = p_invoice_id;

  -- No signed note yet: fall back to the quoted line price. Same agreement, one step
  -- earlier, and an invoice with no figure at all is worse than one marked computed.
  if v_sub is null then
    select sum(qi.price_before_vat * ii.invoiced_qty)
      into v_sub
      from qvm_new_apps.invoice_items ii
      join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = ii.confirmed_item_id
      join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
     where ii.invoice_id = p_invoice_id;
  end if;

  -- The rate the note itself carries, falling back to the statutory 15% only when the note
  -- does not say. Hard-coding it outright would silently misprice the day it changes.
  v_rate  := coalesce(v_rate, 15);
  v_vat   := round(coalesce(v_sub, 0) * v_rate / 100, 2);
  v_total := round(coalesce(v_sub, 0) + v_vat, 2);

  update qvm_new_apps.invoices i set
    subtotal = v_sub, vat = v_vat, total = v_total,
    -- Never overwrite figures Zoho confirmed with ones we worked out ourselves.
    amounts_source = case when i.amounts_source = 'zoho' then 'zoho' else 'computed' end,
    due_date = coalesce(i.due_date,
      (i.created_at::date + coalesce((
        select c.payment_terms_days from qvm_new_apps.customers c
         join qvm_new_apps.client_branches cb on cb.customer_id = c.customer_id
         join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = i.confirmed_order_id
         join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
         join qvm_new_apps.user_data u on u.user_id = q.service_advisor
        where cb.list_data_id = u.user_branch limit 1), 0)))
   where i.invoice_id = p_invoice_id
     and i.amounts_source <> 'manual';
end
$function$;

do $seed$
declare r record;
begin
  for r in select invoice_id from qvm_new_apps.invoices where amounts_source = 'computed' loop
    perform qvm_new_apps.invoice_compute_amounts(r.invoice_id);
  end loop;
end
$seed$;
