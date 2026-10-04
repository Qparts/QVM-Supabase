-- A supplier invoice's lines read like the purchase order's.
--
-- The invoice detail on the supplier-invoices page listed a line with its quantity and cost only.
-- The purchase order's receipt modal reads the same line as required / received / cancelled /
-- returned, with the item's status. `vendor_document_items` now carries those facts on every line
-- (invoice and credit note alike), so the two screens say the same thing about the same line.
-- Additive: every existing key is unchanged.

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_document_items(p_doc_kind text, p_doc_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
               -- The line as the purchase order's receipt modal reads it: what was ordered before
               -- anything was cancelled off it, what arrived, what was cancelled, what went back.
               'item_status_name', (select ld2.list_data from qvm_new_apps.list_data ld2 where ld2.list_data_id = ci.item_status),
               'required_qty', coalesce(pi.approved_qty, 0) + cq.cancelled_qty,
               'received_total', rt.received_total,
               'cancelled_qty', cq.cancelled_qty,
               'returned_qty', coalesce(pi.returned_qty, 0),
               'is_cancelled', coalesce(pi.approved_qty, 0) = 0 and rt.received_total = 0
                               and (cq.cancelled_qty > 0 or pi.vendor_item_status = 160 or ci.item_status = 18),
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
        cross join lateral (
          select coalesce(sum(ri.received_qty), 0)::int as received_total
            from qvm_new_apps.purchase_receipt_round_items ri
           where ri.purchase_item_id = pi.purchase_item_id) rt
        cross join lateral (
          select coalesce(sum(c.qty), 0)::int as cancelled_qty
            from qvm_new_apps.quotation_item_cancellations c
           where c.purchase_item_id = pi.purchase_item_id) cq
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
               -- The line as the purchase order's receipt modal reads it: what was ordered before
               -- anything was cancelled off it, what arrived, what was cancelled, what went back.
               'item_status_name', (select ld2.list_data from qvm_new_apps.list_data ld2 where ld2.list_data_id = ci.item_status),
               'required_qty', coalesce(pi.approved_qty, 0) + cq.cancelled_qty,
               'received_total', rt.received_total,
               'cancelled_qty', cq.cancelled_qty,
               'returned_qty', coalesce(pi.returned_qty, 0),
               'is_cancelled', coalesce(pi.approved_qty, 0) = 0 and rt.received_total = 0
                               and (cq.cancelled_qty > 0 or pi.vendor_item_status = 160 or ci.item_status = 18),
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
        cross join lateral (
          select coalesce(sum(ri.received_qty), 0)::int as received_total
            from qvm_new_apps.purchase_receipt_round_items ri
           where ri.purchase_item_id = pi.purchase_item_id) rt
        cross join lateral (
          select coalesce(sum(c.qty), 0)::int as cancelled_qty
            from qvm_new_apps.quotation_item_cancellations c
           where c.purchase_item_id = pi.purchase_item_id) cq
       where cni.vendor_creditnote_id = p_doc_id) k)
  end;
$function$;
