-- The order lines a vendor may raise an invoice against.
--
-- get_purchase_invoices_dashboard answers the same question for the workshop and cannot answer it
-- for a vendor: it scopes its rows by the caller's client branch and role, so a vendor gets
-- nothing back from it. This is the same set seen from the other side of the trade — the lines
-- THIS vendor won, whoever bought them.
--
-- The shape is deliberately the one PurchaseInvoiceRow already has, so the smart-upload screen can
-- match an invoice against these rows with the code it already uses. Two screens reading two
-- shapes of the same fact is how they come to disagree about it.
--
-- quotation_vendor_items.vendor_id is the awarded vendor, and it is the only row filter there is:
-- a line this vendor did not win is not in the answer, not even as a redacted row.
create or replace function qvm_new_apps.vendor_open_purchase_lines(
  p_search     text default null,
  -- Lines already carrying the vendor's invoice are excluded by default: this list exists to be
  -- invoiced, and a list mostly made of things already done stops being read.
  p_missing_pi boolean default true,
  p_limit      integer default 200,
  p_offset     integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_q      text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows   jsonb; v_total bigint;
begin
  if v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'not a vendor', 'data', null);
  end if;

  with latest_po as (
    select distinct on (pi.confirmed_item_id)
           pi.confirmed_item_id, po.purchase_order_id,
           po.vendor_invoice_url, po.vendor_invoice_number
      from qvm_new_apps.purchase_items pi
      join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
     order by pi.confirmed_item_id, po.purchase_order_id desc
  )
  select coalesce(jsonb_agg(x order by ord desc), '[]'::jsonb), coalesce(max(n), 0)
    into v_rows, v_total
    from (
      select count(*) over () as n, ci.confirmed_item_id as ord, jsonb_build_object(
               'confirmed_item_id', ci.confirmed_item_id,
               'confirmed_order_id', co.confirmed_order_id,
               'quotation_item_id', ci.quotation_item_id,
               'order_number', q.order_number,
               'rfq_date', q.created_at,
               'confirmation_date', co.created_at,
               'delivered_by_name', null,
               'purchase_order_id', lpo.purchase_order_id,
               'receipt_status', pit.receipt_status,
               'received_qty', pit.received_qty,
               'vendor_invoice_url', lpo.vendor_invoice_url,
               'vendor_invoice_number', lpo.vendor_invoice_number,
               'vendor_creditnote_url', null,
               'vendor_creditnote_attachments', '[]'::jsonb,
               'invoice_attachments', '[]'::jsonb,
               'branch_name', cb.branch_name,
               'model', qi.model,
               'main_brand', ldb.list_data,
               'part_description', qi.part_description,
               'final_part_number', ci.final_part_number,
               'final_brand_class', ldf.list_data,
               'approved_qty', ci.approved_qty,
               'purchase_cost', qvi.cost,
               'vendor_name', vnd.vendor_name) as x
        from qvm_new_apps.confirmed_items ci
        join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = ci.confirmed_order_id
        join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
        left join qvm_new_apps.list_data ldb on ldb.list_data_id = qi.main_brand
        left join qvm_new_apps.list_data ldf on ldf.list_data_id = ci.final_brand_class
        -- The awarded vendor. This join is the permission check as much as the lookup.
        join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
        left join qvm_new_apps.vendors vnd on vnd.vendor_id = qvi.vendor_id
        left join latest_po lpo on lpo.confirmed_item_id = ci.confirmed_item_id
        left join qvm_new_apps.purchase_items pit
               on pit.confirmed_item_id = ci.confirmed_item_id
              and pit.purchase_order_id = lpo.purchase_order_id
       where qvi.vendor_id = v_vendor
         and (not p_missing_pi or lpo.vendor_invoice_url is null)
         and (v_q is null
              or q.order_number ilike '%'||v_q||'%'
              or coalesce(ci.final_part_number,'') ilike '%'||v_q||'%'
              or coalesce(qi.part_description,'') ilike '%'||v_q||'%')
       order by ci.confirmed_item_id desc
       limit least(greatest(coalesce(p_limit, 200), 1), 500)
      offset greatest(coalesce(p_offset, 0), 0)) k;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'vendor_id', v_vendor));
end
$$;

revoke all on function qvm_new_apps.vendor_open_purchase_lines(text, boolean, integer, integer) from public;
grant execute on function qvm_new_apps.vendor_open_purchase_lines(text, boolean, integer, integer)
  to authenticated, service_role;
