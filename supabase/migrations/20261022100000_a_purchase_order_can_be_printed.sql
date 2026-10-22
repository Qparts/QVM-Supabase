-- A purchase order can be downloaded as a PDF from the purchase-invoices page. That page lists one
-- row per confirmed item, so the document is found from the row: the item's latest purchase order,
-- with every item on that order, the vendor, the vehicle and the order number (the Job ID).
--
-- Who may read it: internal users, and the client side of the order — a Client Admin of the
-- company that owns the order's branch, or a user of that branch.
create or replace function qvm_new_apps.get_purchase_order_document(
  p_confirmed_item_id integer default null,
  p_purchase_order_id bigint default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_po      qvm_new_apps.purchase_orders%rowtype;
  v_qid     integer;
  v_me      record;
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated');
  end if;

  if p_purchase_order_id is not null then
    select * into v_po from qvm_new_apps.purchase_orders where purchase_order_id = p_purchase_order_id;
  elsif p_confirmed_item_id is not null then
    select po.* into v_po
      from qvm_new_apps.purchase_items pi
      join qvm_new_apps.purchase_orders po on po.purchase_order_id = pi.purchase_order_id
     where pi.confirmed_item_id = p_confirmed_item_id
     order by po.created_at desc
     limit 1;
  end if;
  if v_po.purchase_order_id is null then
    return jsonb_build_object('status', false, 'message', 'No purchase order for this item yet');
  end if;

  select co.quotation_id into v_qid from qvm_new_apps.confirmed_orders co where co.confirmed_order_id = v_po.confirmed_order_id;

  select ud.user_role, ud.user_company, ud.user_branch into v_me from qvm_new_apps.user_data ud where ud.user_id = auth.uid();
  if not qvm_new_apps.is_internal_user()
     and not exists (
       select 1 from qvm_new_apps.quotation_items qi
         join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
        where qi.quotation_id = v_qid
          and ((v_me.user_role = 170 and cb.list_data_id = v_me.user_company) or qi.customer_id = v_me.user_branch)) then
    return jsonb_build_object('status', false, 'message', 'Not allowed');
  end if;

  return jsonb_build_object(
    'status', true,
    'purchase_order_id', v_po.purchase_order_id,
    'created_at', v_po.created_at,
    'order_number', (select q.order_number from qvm_new_apps.quotations q where q.quotation_id = v_qid),
    'vendor_name', (select v.vendor_name from qvm_new_apps.vendors v where v.vendor_id = v_po.vendor_id),
    'vendor_invoice_number', v_po.vendor_invoice_number,
    'vehicle', (select jsonb_build_object(
                  'vin', qi.vin, 'make', ld.list_data, 'model', qi.model, 'year', qi.year,
                  'plate_number', (select q.plate_number from qvm_new_apps.quotations q where q.quotation_id = v_qid))
                  from qvm_new_apps.quotation_items qi
                  left join qvm_new_apps.list_data ld on ld.list_data_id = qi.main_brand
                 where qi.quotation_id = v_qid
                 order by (qi.main_brand is null), qi.quotation_item_id limit 1),
    'branch', (select cb.branch_name from qvm_new_apps.quotation_items qi
                 join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
                where qi.quotation_id = v_qid order by qi.quotation_item_id limit 1),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'purchase_item_id', pi.purchase_item_id,
               'part_number', coalesce(nullif(btrim(qvi.vendor_part_number), ''), nullif(btrim(ci.final_part_number), ''), nullif(btrim(qi.part_number), '')),
               'part_description', qi.part_description,
               'quantity', coalesce(pi.approved_qty, ci.approved_qty, qi.quantity, 1),
               'type', coalesce(fbc.list_data, bc.list_data),
               'unit_cost', coalesce(pi.final_purchase_price, qvi.cost, 0)
             ) order by pi.purchase_item_id)
        from qvm_new_apps.purchase_items pi
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = pi.cost_id
        left join qvm_new_apps.list_data fbc on fbc.list_data_id = ci.final_brand_class
        left join qvm_new_apps.list_data bc on bc.list_data_id = qi.brand_class
       where pi.purchase_order_id = v_po.purchase_order_id), '[]'::jsonb));
end;
$function$;

revoke all on function qvm_new_apps.get_purchase_order_document(integer, bigint) from public;
grant execute on function qvm_new_apps.get_purchase_order_document(integer, bigint) to authenticated, service_role;

notify pgrst, 'reload schema';
