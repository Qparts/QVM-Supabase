-- When an invoice names its lines, show those lines.
--
-- vendor_document_items lists every line of every order the invoice touches. That is the right
-- answer when nobody said otherwise, and the wrong one the moment somebody did: an invoice for two
-- parts out of an order of nine would list nine lines under a total that covers two, and whoever
-- approves it is being shown the order, not the invoice.
--
-- So: if the paper named its lines, those are the lines. Otherwise the order's, as before. The
-- fallback is not a temporary measure — the smart upload reads a total off an image and has no
-- line numbers to give, and «all the lines of the order this was filed against» is the honest
-- answer there.
create or replace function qvm_new_apps.vendor_document_items(p_doc_kind text, p_doc_id bigint)
returns jsonb
language sql
stable
as $$
  select case when p_doc_kind = 'invoice' then (
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) from (
      select pi.purchase_item_id as ord, jsonb_build_object(
               'purchase_item_id', pi.purchase_item_id,
               'po_text', 'PO-' || pi.purchase_order_id,
               'purchase_order_id', pi.purchase_order_id,
               'part_code', ci.final_part_number,
               'part_name', qi.part_description,
               'brand', ld.list_data,
               'receipt_status', coalesce(pi.receipt_status, 'not_received'),
               'received_at', pi.receipt_status_updated_at,
               'qty', coalesce(pi.received_qty, pi.approved_qty),
               'unit_cost', coalesce(pi.final_purchase_price, qvi.cost),
               'line_total', coalesce(pi.received_qty, pi.approved_qty)
                             * coalesce(pi.final_purchase_price, qvi.cost, 0),
               -- True when the paper named this line itself, rather than it being inherited from
               -- the order. The screen can then say so instead of implying every invoice is
               -- line-accurate.
               'claimed', exists (select 1 from qvm_new_apps.purchase_invoice_lines pl
                                   join qvm_new_apps.purchase_invoice_attachments pa
                                     on pa.attachment_id = pl.attachment_id
                                  where pa.invoice_group_id = g.grp
                                    and pl.confirmed_item_id = pi.confirmed_item_id)) as x
        from (select gg.invoice_group_id as grp,
                     exists (select 1 from qvm_new_apps.purchase_invoice_lines pl2
                               join qvm_new_apps.purchase_invoice_attachments pa2
                                 on pa2.attachment_id = pl2.attachment_id
                              where pa2.invoice_group_id = gg.invoice_group_id) as has_lines
                from qvm_new_apps.purchase_invoice_attachments gg
               where gg.attachment_id = p_doc_id) g
        join qvm_new_apps.purchase_invoice_attachments a
          on a.invoice_group_id = g.grp
        join qvm_new_apps.purchase_items pi
          on pi.purchase_order_id = a.purchase_order_id
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class
        left join lateral (
          select qvi.cost from qvm_new_apps.quotation_vendor_items qvi
           where qvi.cost_id = coalesce(pi.cost_id, qi.cost_id)
           order by qvi.cost_id limit 1) qvi on true
        -- Named lines win; with none named, the order's lines stand in.
       where not g.has_lines
          or exists (select 1 from qvm_new_apps.purchase_invoice_lines pl
                       join qvm_new_apps.purchase_invoice_attachments pa
                         on pa.attachment_id = pl.attachment_id
                      where pa.invoice_group_id = g.grp
                        and pl.confirmed_item_id = pi.confirmed_item_id)) k)
  else (
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) from (
      select cni.id as ord, jsonb_build_object(
               'purchase_item_id', pi.purchase_item_id,
               'po_text', 'PO-' || pi.purchase_order_id,
               'purchase_order_id', pi.purchase_order_id,
               'part_code', ci.final_part_number,
               'part_name', qi.part_description,
               'brand', ld.list_data,
               'receipt_status', coalesce(pi.receipt_status, 'not_received'),
               'received_at', pi.receipt_status_updated_at,
               'qty', cni.return_qty,
               'unit_cost', coalesce(pi.final_purchase_price, qvi.cost),
               'line_total', coalesce(cni.return_qty, 0)
                             * coalesce(pi.final_purchase_price, qvi.cost, 0),
               'claimed', true) as x
        from qvm_new_apps.vendor_creditnote_items cni
        join qvm_new_apps.purchase_items pi on pi.purchase_item_id = cni.purchase_item_id
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class
        left join lateral (
          select qvi.cost from qvm_new_apps.quotation_vendor_items qvi
           where qvi.cost_id = coalesce(pi.cost_id, qi.cost_id)
           order by qvi.cost_id limit 1) qvi on true
       where cni.vendor_creditnote_id = p_doc_id) k)
  end;
$$;
