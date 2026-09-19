-- The lines behind a document, and the screen where a supplier actually gets paid.
--
-- First a correction. vendor_document_detail computed each line as purchase_items.final_purchase_price
-- × quantity, and on dev every line came back 0 against an invoice of 230: final_purchase_price is
-- null on these rows, and purchase_items.cost_id is null with it. The price that was actually agreed
-- lives one join further out — the quotation item's cost, which is the vendor's winning bid — and
-- that is the same path vendor_open_purchase_lines already reads a price from. The stored price wins
-- when there is one; the awarded cost is the fallback.
--
-- The item list is now one function instead of a copy inside every screen that needs it. It was
-- already written twice (invoice and return branches of the detail) and the settlement screen below
-- would have been the third and fourth. Four copies of a join is four places for a price to be
-- wrong differently.
--
-- What the lines do NOT do is add up to the invoice. They are what we agreed to pay; the total is
-- what the supplier billed, tax and shipping included. The design keeps «الإجمالي (شامل الضريبة)»
-- in its own row for exactly that reason, and nothing here tries to reconcile the two — that
-- difference is information, and a function that hid it would be hiding the disagreement the whole
-- approval step exists to catch.
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
                             * coalesce(pi.final_purchase_price, qvi.cost, 0)) as x
        from qvm_new_apps.purchase_items pi
        join qvm_new_apps.purchase_invoice_attachments a
          on a.purchase_order_id = pi.purchase_order_id and a.attachment_id = p_doc_id
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class
        -- One bid per line: a LATERAL rather than a join, because a cost_id with two vendor rows
        -- would otherwise duplicate the line and double its money.
        left join lateral (
          select qvi.cost from qvm_new_apps.quotation_vendor_items qvi
           where qvi.cost_id = coalesce(pi.cost_id, qi.cost_id)
           order by qvi.cost_id limit 1) qvi on true) k)
  else (
    -- A credit note lists what went back, not what was bought: its quantity is the returned one.
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
                             * coalesce(pi.final_purchase_price, qvi.cost, 0)) as x
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

-- The detail now reads its lines from there instead of carrying its own pair of copies.
create or replace function qvm_new_apps.vendor_document_detail(p_doc_kind text, p_doc_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_side   text := case when v_team then 'purchasing' else 'vendor' end;
  v_list   jsonb;
  v_header jsonb;
  v_file   jsonb;
  v_unreceived integer := 0;
begin
  v_list := qvm_new_apps.vendor_documents_list(null, null, null, null, 1, 0,
              p_doc_kind || ':' || p_doc_id);
  if not coalesce((v_list->>'status')::boolean, false) then
    return v_list;
  end if;
  v_header := v_list->'data'->'rows'->0;
  if v_header is null then
    -- Absent and not-yours are answered identically on purpose: the difference would tell a
    -- supplier that a document they cannot see exists.
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
             -- The frontend opens the existing goods-receipt screen by purchase order rather than
             -- linking a document we do not store: that screen already exists and already knows
             -- how to render «إشعار استلام البضاعة».
             'purchase_order_id', a.purchase_order_id,
             'confirmed_order_id', a.confirmed_order_id)
      into v_file
      from qvm_new_apps.purchase_invoice_attachments a
      left join qvm_new_apps.user_data up on up.user_id = a.uploaded_by
      left join qvm_new_apps.user_data ap on ap.user_id = a.approved_by
     where a.attachment_id = p_doc_id;

    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
      join qvm_new_apps.purchase_invoice_attachments a
        on a.purchase_order_id = pi.purchase_order_id and a.attachment_id = p_doc_id
     where coalesce(pi.receipt_status, 'not_received') <> 'received';
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
    'notes', qvm_new_apps.vendor_notes_of(p_doc_kind, p_doc_id, v_side),
    'side', v_side,
    -- The button's own rules, answered here so the screen does not re-derive them and drift.
    'can_approve', v_team and (v_header->>'state') = 'draft' and v_unreceived = 0,
    'approve_blocked_reason', case
      when not v_team then 'الاعتماد من صلاحية المشتريات'
      when (v_header->>'state') <> 'draft' then null
      when v_unreceived > 0 then 'لا يمكن الاعتماد حتى يتم استلام جميع الأصناف'
      else null end,
    'unreceived_count', v_unreceived));
end
$$;

-- ── The settlement requests ────────────────────────────────────────────────────────────────────
-- Both sides read the same list, scoped the same way documents are: the buying team sees every
-- request, a supplier sees the ones raised against them.
--
-- The breakdown is counted from the member rows rather than stored on the request, because a
-- request can close on some of its documents and release the rest, and the header's single status
-- cannot say which was which.
create or replace function qvm_new_apps.vendor_settlements_list(
  p_status text default null,
  p_limit  integer default 50,
  p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_rows jsonb; v_total bigint; v_counts jsonb;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with mine as (
    select s.*, v.vendor_name
      from qvm_new_apps.vendor_settlements s
      left join qvm_new_apps.vendors v on v.vendor_id = s.vendor_id
     where v_team or s.vendor_id = v_vendor
  ), counted as (
    select m.*,
           (select count(*) from qvm_new_apps.vendor_settlement_items i
             where i.settlement_id = m.settlement_id and i.doc_kind = 'invoice') as invoice_count,
           (select count(*) from qvm_new_apps.vendor_settlement_items i
             where i.settlement_id = m.settlement_id and i.doc_kind = 'return') as return_count,
           (select jsonb_object_agg(member_status, n) from (
              select i.member_status, count(*) as n
                from qvm_new_apps.vendor_settlement_items i
               where i.settlement_id = m.settlement_id
               group by i.member_status) b) as member_breakdown
      from mine m
  ), filtered as (
    select c.*, count(*) over () as n from counted c
     where (p_status is null or p_status = '' or p_status = 'all' or c.status = p_status)
     order by c.created_at desc, c.settlement_id desc
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select coalesce(jsonb_agg(jsonb_build_object(
            'settlement_id', f.settlement_id, 'code', f.code,
            'vendor_id', f.vendor_id, 'vendor_name', f.vendor_name,
            'created_at', f.created_at, 'status', f.status,
            'raised_by_side', f.raised_by_side,
            'invoice_count', f.invoice_count, 'return_count', f.return_count,
            'net_amount', f.net_amount,
            'member_breakdown', coalesce(f.member_breakdown, '{}'::jsonb),
            'bank_account', f.bank_account, 'transfer_ref', f.transfer_ref,
            'receipt_url', f.receipt_url, 'settled_at', f.settled_at)
          order by f.created_at desc, f.settlement_id desc), '[]'::jsonb) from filtered f),
         (select coalesce(max(n), 0) from filtered),
         (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
            from (select status, count(*) as n from mine group by status) k)
    into v_rows, v_total, v_counts;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts,
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'vendor_id', v_vendor));
end
$$;

-- ── One request, opened ────────────────────────────────────────────────────────────────────────
-- The screen where the buying side picks which of the request's documents this transfer covers,
-- names the account, attaches the receipt, and closes it.
--
-- Each member document is read back through vendor_documents_list by its doc_key, so the amounts
-- and states on this screen are the same ones the invoices table showed. The amount frozen on the
-- member row is returned beside the live one rather than instead of it: the first is what the
-- request was raised for, the second is what is owed now, and a partial settlement in between makes
-- them differ. Showing only one of them would be a guess about which question was being asked.
--
-- The bank accounts are not free text and not a fixed list. They are the accounts this supplier
-- registered on their own branches — the only accounts a transfer can honestly be sent to.
create or replace function qvm_new_apps.vendor_settlement_detail(p_settlement_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_side   text := case when v_team then 'purchasing' else 'vendor' end;
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_head   jsonb;
  v_vid    integer;
  v_status text;
  v_members jsonb;
  v_banks  jsonb;
begin
  select jsonb_build_object(
           'settlement_id', s.settlement_id, 'code', s.code, 'status', s.status,
           'vendor_id', s.vendor_id, 'vendor_name', v.vendor_name,
           'raised_by_side', s.raised_by_side, 'net_amount', s.net_amount,
           'bank_account', s.bank_account, 'transfer_ref', s.transfer_ref,
           'receipt_url', s.receipt_url, 'receipt_path', s.receipt_path,
           'created_at', s.created_at, 'created_by_name', cu.user_name,
           'settled_at', s.settled_at, 'settled_by_name', su.user_name,
           'cancelled_at', s.cancelled_at),
         s.vendor_id, s.status
    into v_head, v_vid, v_status
    from qvm_new_apps.vendor_settlements s
    left join qvm_new_apps.vendors v on v.vendor_id = s.vendor_id
    left join qvm_new_apps.user_data cu on cu.user_id = s.created_by
    left join qvm_new_apps.user_data su on su.user_id = s.settled_by
   where s.settlement_id = p_settlement_id;

  if v_head is null or not (v_team or v_vid = v_vendor) then
    return jsonb_build_object('status', false, 'message', 'طلب التسوية غير موجود', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', i.item_id, 'doc_kind', i.doc_kind, 'doc_id', i.doc_id,
           'doc_key', i.doc_kind || ':' || i.doc_id,
           'member_status', i.member_status,
           -- What the request was raised for, kept beside what is owed today.
           'amount_at_request', i.amount,
           'document', d.row,
           'days_since_issue', case when d.row->>'issued_on' is null then null
                                    else current_date - (d.row->>'issued_on')::date end,
           'items', qvm_new_apps.vendor_document_items(i.doc_kind, i.doc_id))
         order by i.item_id), '[]'::jsonb)
    into v_members
    from qvm_new_apps.vendor_settlement_items i
    cross join lateral (
      select (qvm_new_apps.vendor_documents_list(null, null, null, null, 1, 0,
                i.doc_kind || ':' || i.doc_id))->'data'->'rows'->0 as row) d
   where i.settlement_id = p_settlement_id;

  select coalesce(jsonb_agg(b order by b->>'bank_iban'), '[]'::jsonb) into v_banks
    from (select distinct jsonb_build_object(
                   'bank_name', e->>'bank_name',
                   'bank_iban', e->>'bank_iban',
                   'bank_account_name', e->>'bank_account_name') as b
            from qvm_new_apps.vendor_branches vb
            cross join lateral jsonb_array_elements(
              case when jsonb_typeof(vb.banks) = 'array' then vb.banks else '[]'::jsonb end) e
           where vb.vendor_id = v_vid and nullif(e->>'bank_iban', '') is not null) k;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'header', v_head, 'members', v_members, 'bank_accounts', v_banks,
    'notes', qvm_new_apps.vendor_notes_of('settlement', p_settlement_id, v_side),
    'side', v_side,
    -- Money leaves on confirm, so only the buying side sees the button at all.
    'can_settle', v_team and v_status = 'pending',
    'can_cancel', v_team and v_status = 'pending'));
end
$$;

revoke all on function qvm_new_apps.vendor_document_items(text, bigint) from public;
revoke all on function qvm_new_apps.vendor_settlements_list(text, integer, integer) from public;
revoke all on function qvm_new_apps.vendor_settlement_detail(bigint) from public;
grant execute on function qvm_new_apps.vendor_settlements_list(text, integer, integer),
                          qvm_new_apps.vendor_settlement_detail(bigint)
  to authenticated, service_role;
