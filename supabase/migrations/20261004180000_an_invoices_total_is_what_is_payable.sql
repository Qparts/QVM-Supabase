-- An invoice's total is what is payable; in full it is that plus its credit note.
--
-- The amount filed on a purchase invoice is what is payable after the credit note uploaded with
-- it — the purchase order's value, which already leaves the returned lines out. The previous
-- migration treated it as the invoice in full and subtracted the credit note from it, deducting
-- the returns twice. Now a merged row's `total` and `signed_total` are the invoice's own, and
-- `invoice_total` is the invoice in full: the filed amount plus the credit note. The detail says
-- the same: `invoice_total` in full, `return_total` the credit, `net_total` the filed amount.
--
-- A linked credit note is therefore never a document of its own: it leaves the counts and the
-- KPIs (`linked`), a settlement names the invoice alone, and paying the invoice settles it.

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_documents_list(p_status text DEFAULT NULL::text, p_doc_type text DEFAULT NULL::text, p_vendor integer DEFAULT NULL::integer, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_doc_key text DEFAULT NULL::text, p_party text DEFAULT NULL::text, p_po text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_q      text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb; v_total bigint; v_counts jsonb; v_kpi jsonb; v_facets jsonb;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with inv as (
    select a.invoice_group_id as grp,
           min(a.attachment_id) as doc_id,
           max(nullif(a.invoice_number,'')) as code,
           min(coalesce(a.issued_on, a.uploaded_at::date)) as issued_on,
           max(a.payment_term_days) as term_days,
           max(coalesce(a.total_amount, 0)) as total,
           max(coalesce(a.settled_amount, 0)) as settled,
           max(a.approved_at) as approved_at,
           max(a.cancelled_at) as cancelled_at,
           max(a.match_pct) as match_pct,
           min(a.uploaded_at) as uploaded_at,
           min(a.confirmed_order_id) as confirmed_order_id,
           array_agg(distinct a.purchase_order_id) as po_ids,
           count(*) as order_count
      from qvm_new_apps.purchase_invoice_attachments a
     group by a.invoice_group_id
  ), docs as (
    select 'invoice'::text as doc_kind, i.doc_id,
           'invoice:' || i.doc_id as doc_key,
           i.code, i.code is null as code_missing,
           v.vendor_id, v.vendor_name, coalesce(cb.branch_name, '—') as party,
           'PO-' || array_to_string(i.po_ids, ', PO-') as po_text,
           i.order_count,
           i.issued_on, i.term_days,
           i.issued_on + coalesce(i.term_days, 30) as due_on,
           i.total, i.settled,
           i.total - i.settled as signed_total,
           qvm_new_apps.vendor_document_state(
             i.approved_at, i.cancelled_at, i.total, i.settled, i.issued_on, i.term_days,
             not exists (select 1 from qvm_new_apps.purchase_items pi
                          where pi.purchase_order_id = any (i.po_ids)
                            and coalesce(pi.receipt_status, 'not_received') <> 'received')) as state,
           st.code as settlement_code, st.transfer_ref, i.match_pct, i.uploaded_at,
           i.grp as invoice_group_id,
           false as linked
      from inv i
      left join lateral (
        select cb.branch_name, vv.vendor_id, vv.vendor_name
          from qvm_new_apps.confirmed_items ci
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
          left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
          left join qvm_new_apps.vendors vv on vv.vendor_id = qvi.vendor_id
         where ci.confirmed_order_id = i.confirmed_order_id
         order by ci.confirmed_item_id limit 1) v on true
      left join lateral (select v.branch_name) cb(branch_name) on true
      left join lateral (
        select s.code, s.transfer_ref from qvm_new_apps.vendor_settlement_items si
          join qvm_new_apps.vendor_settlements s on s.settlement_id = si.settlement_id
         where si.doc_kind = 'invoice' and si.doc_id = i.doc_id
           and si.member_status <> 'cancelled'
         order by si.item_id desc limit 1) st on true
     where (v_team or v.vendor_id = v_vendor)
    union all
    select 'return', cn.vendor_creditnote_id,
           'return:' || cn.vendor_creditnote_id,
           nullif(cn.vendor_creditnote_number,''),
           nullif(cn.vendor_creditnote_number,'') is null,
           v.vendor_id, v.vendor_name, coalesce(cb.branch_name, '—'),
           'PO-' || cn.purchase_order_id,
           1,
           coalesce(cn.issued_on, cn.created_at::date), 0,
           coalesce(cn.issued_on, cn.created_at::date),
           coalesce(cn.total_amount, 0), coalesce(cn.settled_amount, 0),
           -(coalesce(cn.total_amount, 0) - coalesce(cn.settled_amount, 0)),
           qvm_new_apps.vendor_document_state(
             cn.approved_at, cn.cancelled_at, cn.total_amount, cn.settled_amount,
             coalesce(cn.issued_on, cn.created_at::date), 0, true),
           st.code, st.transfer_ref, null, cn.created_at,
           cn.invoice_group_id,
           -- Filed with an invoice: its value already sits inside that invoice's payable amount,
           -- so it is read with the invoice and never counted on its own.
           (cn.invoice_group_id is not null and exists (
              select 1 from qvm_new_apps.purchase_invoice_attachments a
               where a.invoice_group_id = cn.invoice_group_id)) as linked
      from qvm_new_apps.vendor_creditnotes cn
      left join lateral (
        select cb.branch_name, vv.vendor_id, vv.vendor_name
          from qvm_new_apps.purchase_items pi2
          join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi2.confirmed_item_id
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
          left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
          left join qvm_new_apps.vendors vv on vv.vendor_id = qvi.vendor_id
         where pi2.purchase_order_id = cn.purchase_order_id
         order by pi2.confirmed_item_id limit 1) v on true
      left join lateral (select v.branch_name) cb(branch_name) on true
      left join lateral (
        select s.code, s.transfer_ref from qvm_new_apps.vendor_settlement_items si
          join qvm_new_apps.vendor_settlements s on s.settlement_id = si.settlement_id
         where si.doc_kind = 'return' and si.doc_id = cn.vendor_creditnote_id
           and si.member_status <> 'cancelled'
         order by si.item_id desc limit 1) st on true
     where (v_team or v.vendor_id = v_vendor)
  ), filtered as (
    -- An invoice and the credit note filed with it are one row of the list: the invoice's row,
    -- carrying the credit note's total, with the net owed. The credit note's own row is kept out
    -- of the list. Asked for one document by key (the detail, a settlement) each stands alone
    -- again, so a settlement nets the two from their own amounts and settles each of them.
    select d.*,
           coalesce(r.return_total, 0) as return_total,
           coalesce(r.return_settled, 0) as return_settled,
           r.return_doc_ids, r.return_codes,
           (r.return_doc_ids is not null) as has_return,
           -- The invoice as filed is what is payable after the credit; the invoice in full is that
           -- plus the credit note.
           d.total + coalesce(r.return_total, 0) as invoice_total,
           count(*) over () as n
      from docs d
      left join lateral (
        select sum(coalesce(cn.total_amount, 0)) as return_total,
               sum(coalesce(cn.settled_amount, 0)) as return_settled,
               array_agg(cn.vendor_creditnote_id order by cn.vendor_creditnote_id) as return_doc_ids,
               string_agg(nullif(cn.vendor_creditnote_number, ''), ', ') as return_codes
          from qvm_new_apps.vendor_creditnotes cn
         where p_doc_key is null and d.doc_kind = 'invoice'
           and cn.invoice_group_id = d.invoice_group_id and cn.cancelled_at is null
      ) r on true
     where (p_doc_key is null or d.doc_key = p_doc_key)
       and (p_doc_key is not null or not d.linked)
       and (p_status is null or p_status = '' or p_status = 'all' or d.state = p_status)
       and (p_doc_type is null or p_doc_type = '' or p_doc_type = 'all' or d.doc_kind = p_doc_type
            or (p_doc_type = 'invoice_return' and r.return_doc_ids is not null))
       and (p_vendor is null or d.vendor_id = p_vendor)
       and (p_party is null or p_party = '' or d.party = p_party)
       and (p_po is null or p_po = '' or d.po_text = p_po or d.po_text like '%' || p_po || '%')
       and (v_q is null or coalesce(d.code,'') ilike '%'||v_q||'%' or d.po_text ilike '%'||v_q||'%'
            or coalesce(d.vendor_name,'') ilike '%'||v_q||'%'
            or coalesce(d.party,'') ilike '%'||v_q||'%')
     order by d.issued_on desc, d.doc_id desc
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select coalesce(jsonb_agg(
            (to_jsonb(f) - 'n')
            order by f.issued_on desc, f.doc_id desc), '[]'::jsonb) from filtered f),
         (select coalesce(max(n), 0) from filtered),
         (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb)
            from (select state, count(*) as n from docs where not linked group by state) k),
         (select jsonb_build_object(
            'total_overdue',   coalesce(sum(signed_total) filter (where state = 'overdue'), 0),
            'total_approved',  coalesce(sum(signed_total) filter (where state in ('approved','overdue')), 0),
            'total_documents', coalesce(sum(signed_total), 0),
            'total_settled',   coalesce(sum(settled), 0),
            'count',           count(*)) from docs where not linked),
         (select jsonb_build_object(
            'vendors', (select coalesce(jsonb_agg(distinct jsonb_build_object(
                          'vendor_id', vendor_id, 'vendor_name', vendor_name)), '[]'::jsonb)
                          from docs where vendor_id is not null),
            'parties', (select coalesce(jsonb_agg(distinct party), '[]'::jsonb)
                          from docs where party is not null),
            'pos',     (select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
                          from docs, lateral unnest(string_to_array(po_text, ', ')) p
                         where po_text is not null)))
    into v_rows, v_total, v_counts, v_kpi, v_facets;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts, 'kpi', v_kpi, 'facets', v_facets,
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'vendor_id', v_vendor));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_document_detail(p_doc_kind text, p_doc_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_side   text := case when v_team then 'purchasing' else 'vendor' end;
  v_list   jsonb;
  v_header jsonb;
  v_file   jsonb;
  v_unreceived integer := 0;
  v_returns jsonb := '[]'::jsonb;
  v_return_total numeric := 0;
begin
  v_list := qvm_new_apps.vendor_documents_list(p_limit => 1, p_doc_key =>
              p_doc_kind || ':' || p_doc_id);
  if not coalesce((v_list->>'status')::boolean, false) then
    return v_list;
  end if;
  v_header := v_list->'data'->'rows'->0;
  if v_header is null then
    return jsonb_build_object('status', false, 'message', 'المستند غير موجود', 'data', null);
  end if;

  if p_doc_kind = 'invoice' then
    select jsonb_build_object(
             'file_url', a.file_url, 'file_path', a.file_path, 'mime_type', a.mime_type,
             'file_size', a.file_size, 'invoice_number', a.invoice_number,
             'uploaded_at', a.uploaded_at, 'uploaded_source', a.uploaded_source,
             'uploaded_by_name', up.user_name,
             'approved_at', a.approved_at, 'approved_by_name', ap.user_name,
             'match_pct', a.match_pct,
             'amounts_source', a.amounts_source,
             'purchase_order_id', a.purchase_order_id,
             'confirmed_order_id', a.confirmed_order_id)
      into v_file
      from qvm_new_apps.purchase_invoice_attachments a
      left join qvm_new_apps.user_data up on up.user_id = a.uploaded_by
      left join qvm_new_apps.user_data ap on ap.user_id = a.approved_by
     where a.attachment_id = p_doc_id;

    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
     where pi.purchase_order_id in (
             select a.purchase_order_id from qvm_new_apps.purchase_invoice_attachments a
              where a.invoice_group_id = (select g.invoice_group_id
                                            from qvm_new_apps.purchase_invoice_attachments g
                                           where g.attachment_id = p_doc_id))
       and coalesce(pi.receipt_status, 'not_received') <> 'received';

    -- The credit notes filed with this invoice, each with its own lines.
    select coalesce(jsonb_agg(jsonb_build_object(
             'vendor_creditnote_id', cn.vendor_creditnote_id,
             'code', nullif(cn.vendor_creditnote_number, ''),
             'issued_on', coalesce(cn.issued_on, cn.created_at::date),
             'total', coalesce(cn.total_amount, 0),
             'settled', coalesce(cn.settled_amount, 0),
             'file_url', cn.vendor_creditnote_url,
             'uploaded_at', cn.uploaded_at, 'uploaded_by_name', up.user_name,
             'approved_at', cn.approved_at, 'approved_by_name', ap.user_name,
             'items', qvm_new_apps.vendor_document_items('return', cn.vendor_creditnote_id))
             order by cn.vendor_creditnote_id), '[]'::jsonb),
           coalesce(sum(coalesce(cn.total_amount, 0)), 0)
      into v_returns, v_return_total
      from qvm_new_apps.vendor_creditnotes cn
      left join qvm_new_apps.user_data up on up.user_id = cn.uploaded_by
      left join qvm_new_apps.user_data ap on ap.user_id = cn.approved_by
     where cn.cancelled_at is null
       and cn.invoice_group_id = (select g.invoice_group_id
                                    from qvm_new_apps.purchase_invoice_attachments g
                                   where g.attachment_id = p_doc_id);
  else
    select jsonb_build_object(
             'file_url', cn.vendor_creditnote_url, 'file_path', null, 'mime_type', null,
             'file_size', null, 'invoice_number', cn.vendor_creditnote_number,
             'uploaded_at', cn.uploaded_at, 'uploaded_source', cn.uploaded_source,
             'uploaded_by_name', up.user_name,
             'approved_at', cn.approved_at, 'approved_by_name', ap.user_name,
             'match_pct', null,
             'purchase_order_id', cn.purchase_order_id,
             'confirmed_order_id', null)
      into v_file
      from qvm_new_apps.vendor_creditnotes cn
      left join qvm_new_apps.user_data up on up.user_id = cn.uploaded_by
      left join qvm_new_apps.user_data ap on ap.user_id = cn.approved_by
     where cn.vendor_creditnote_id = p_doc_id;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'header', v_header, 'file', v_file,
    'items', qvm_new_apps.vendor_document_items(p_doc_kind, p_doc_id),
    'returns', v_returns,
    'return_total', v_return_total,
    -- The invoice as filed is what is payable; in full it is that plus the credit note.
    'invoice_total', coalesce((v_header->>'total')::numeric, 0) + v_return_total,
    'net_total', coalesce((v_header->>'total')::numeric, 0),
    'notes', qvm_new_apps.vendor_notes_of(p_doc_kind, p_doc_id, v_side),
    'side', v_side,
    'can_approve', v_team and (v_header->>'state') = 'draft' and v_unreceived = 0,
    'approve_blocked_reason', case
      when not v_team then 'الاعتماد من صلاحية المشتريات'
      when (v_header->>'state') <> 'draft' then null
      when v_unreceived > 0 then 'لا يمكن الاعتماد حتى يتم استلام جميع الأصناف'
      else null end,
    'unreceived_count', v_unreceived));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_settlement_settle(p_settlement_id bigint, p_paid_doc_ids jsonb, p_bank_account text DEFAULT NULL::text, p_transfer_ref text DEFAULT NULL::text, p_receipt_url text DEFAULT NULL::text, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_paid integer := 0; v_released integer := 0; r record;
begin
  -- Money leaves on this call. Only the buying side may say it did.
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'تأكيد السداد من صلاحية المشتريات', 'data', null);
  end if;
  if not exists (select 1 from qvm_new_apps.vendor_settlements
                  where settlement_id = p_settlement_id and status = 'pending') then
    return jsonb_build_object('status', false, 'message', 'طلب التسوية غير مفتوح', 'data', null);
  end if;

  for r in select * from qvm_new_apps.vendor_settlement_items
            where settlement_id = p_settlement_id and member_status = 'pending'
  loop
    if p_paid_doc_ids @> to_jsonb(r.doc_id) then
      update qvm_new_apps.vendor_settlement_items
         set member_status = 'settled' where item_id = r.item_id;
      if r.doc_kind = 'invoice' then
        -- Every row of the paper, not the one the request happens to name.
        update qvm_new_apps.purchase_invoice_attachments
           set settled_amount = coalesce(settled_amount,0) + abs(r.amount), settled_at = now()
         where invoice_group_id = (select g.invoice_group_id
                                     from qvm_new_apps.purchase_invoice_attachments g
                                    where g.attachment_id = r.doc_id);
        -- The credit note filed with the invoice was already inside the amount just paid.
        update qvm_new_apps.vendor_creditnotes
           set settled_amount = coalesce(total_amount, 0), settled_at = coalesce(settled_at, now())
         where cancelled_at is null
           and invoice_group_id = (select g.invoice_group_id
                                     from qvm_new_apps.purchase_invoice_attachments g
                                    where g.attachment_id = r.doc_id);
      else
        update qvm_new_apps.vendor_creditnotes
           set settled_amount = coalesce(settled_amount,0) + abs(r.amount), settled_at = now()
         where vendor_creditnote_id = r.doc_id;
      end if;
      v_paid := v_paid + 1;
    else
      -- Released, not destroyed: it is still owed, it just was not in this transfer.
      update qvm_new_apps.vendor_settlement_items
         set member_status = 'cancelled' where item_id = r.item_id;
      v_released := v_released + 1;
    end if;
  end loop;

  update qvm_new_apps.vendor_settlements
     set status = 'settled', settled_at = now(), settled_by = auth.uid(),
         bank_account = coalesce(p_bank_account, bank_account),
         transfer_ref = coalesce(p_transfer_ref, transfer_ref),
         receipt_url  = coalesce(p_receipt_url, receipt_url),
         receipt_path = coalesce(p_receipt_path, receipt_path)
   where settlement_id = p_settlement_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('settled', v_paid, 'released', v_released));
end
$function$;
