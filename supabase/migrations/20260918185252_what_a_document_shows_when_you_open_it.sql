-- Opening one document, and the notes two companies leave on it.
--
-- The header is not rebuilt here. vendor_document_detail asks vendor_documents_list for the one row
-- by its doc_key and returns it as `header`, so the modal cannot show a state, an amount or a due
-- date that differs from the line the user clicked. That call is also the permission check: the
-- list already scopes a vendor to their own documents, so a document that comes back empty is
-- either absent or not theirs, and the caller is told the same thing either way.
--
-- What the detail adds is everything the list has no room for: the original file, who filed it and
-- when, who approved it and when, the AI match, the lines the money is made of, and the notes.
-- ── Notes ──────────────────────────────────────────────────────────────────────────────────────
-- «فريقي فقط» is stored as 'internal' and «الطرفين» as 'both'. An internal note is visible to the
-- side that wrote it and to nobody else — which is why the reader's side has to be passed in
-- rather than recomputed: this is called from functions that have already decided who is asking.
create or replace function qvm_new_apps.vendor_notes_of(p_doc_kind text, p_doc_id bigint, p_side text)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'note_id', n.note_id, 'body', n.body, 'visibility', n.visibility,
           'author_side', n.author_side, 'author_name', u.user_name,
           'attachment_url', n.attachment_url, 'created_at', n.created_at,
           'mine', n.author_side = p_side)
         order by n.created_at desc), '[]'::jsonb)
    from qvm_new_apps.vendor_document_notes n
    left join qvm_new_apps.user_data u on u.user_id = n.author_id
   where n.doc_kind = p_doc_kind and n.doc_id = p_doc_id
     and (n.visibility = 'both' or n.author_side = p_side);
$$;

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
  v_items  jsonb;
  v_notes  jsonb;
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

    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_items
      from (
        select pi.purchase_item_id as ord, jsonb_build_object(
                 'purchase_item_id', pi.purchase_item_id,
                 'po_text', 'PO-' || pi.purchase_order_id,
                 'part_code', ci.final_part_number,
                 'part_name', qi.part_description,
                 'brand', ld.list_data,
                 'receipt_status', coalesce(pi.receipt_status, 'not_received'),
                 'received_at', pi.receipt_status_updated_at,
                 'qty', coalesce(pi.received_qty, pi.approved_qty),
                 'unit_cost', pi.final_purchase_price,
                 'line_total', coalesce(pi.received_qty, pi.approved_qty)
                               * coalesce(pi.final_purchase_price, 0)) as x
          from qvm_new_apps.purchase_items pi
          join qvm_new_apps.purchase_invoice_attachments a
            on a.purchase_order_id = pi.purchase_order_id and a.attachment_id = p_doc_id
          left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
          left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class) k;
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

    -- A credit note lists what went back, not what was bought: its quantity is the returned one.
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_items
      from (
        select cni.id as ord, jsonb_build_object(
                 'purchase_item_id', pi.purchase_item_id,
                 'po_text', 'PO-' || pi.purchase_order_id,
                 'part_code', ci.final_part_number,
                 'part_name', qi.part_description,
                 'brand', ld.list_data,
                 'receipt_status', coalesce(pi.receipt_status, 'not_received'),
                 'received_at', pi.receipt_status_updated_at,
                 'qty', cni.return_qty,
                 'unit_cost', pi.final_purchase_price,
                 'line_total', coalesce(cni.return_qty, 0)
                               * coalesce(pi.final_purchase_price, 0)) as x
          from qvm_new_apps.vendor_creditnote_items cni
          join qvm_new_apps.purchase_items pi on pi.purchase_item_id = cni.purchase_item_id
          left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
          left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class
         where cni.vendor_creditnote_id = p_doc_id) k;
  end if;

  v_notes := qvm_new_apps.vendor_notes_of(p_doc_kind, p_doc_id, v_side);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'header', v_header, 'file', v_file, 'items', v_items, 'notes', v_notes,
    'side', v_side,
    -- The button's own rules, answered here so the screen does not re-derive them and drift.
    'can_approve', v_team and (v_header->>'state') in ('draft')
                   and v_unreceived = 0,
    'approve_blocked_reason', case
      when not v_team then 'الاعتماد من صلاحية المشتريات'
      when (v_header->>'state') <> 'draft' then null
      when v_unreceived > 0 then 'لا يمكن الاعتماد حتى يتم استلام جميع الأصناف'
      else null end,
    'unreceived_count', v_unreceived));
end
$$;

-- Writing one. The document must be one the author can already open — the same read that draws the
-- screen decides whether a note may be left on it, so there is no second, looser rule to keep in
-- step. A settlement is visible to the buying team and to the supplier it names.
create or replace function qvm_new_apps.vendor_note_add(
  p_doc_kind       text,
  p_doc_id         bigint,
  p_body           text,
  p_visibility     text default 'both',
  p_attachment_url text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_side text := case when v_team then 'purchasing' else 'vendor' end;
  v_ok   boolean := false;
  v_id   bigint;
begin
  if nullif(btrim(coalesce(p_body, '')), '') is null and p_attachment_url is null then
    return jsonb_build_object('status', false, 'message', 'الملاحظة فارغة', 'data', null);
  end if;
  if p_visibility not in ('internal', 'both') then
    return jsonb_build_object('status', false, 'message', 'نطاق ظهور غير معروف', 'data', null);
  end if;

  if p_doc_kind = 'settlement' then
    v_ok := v_team or exists (
      select 1 from qvm_new_apps.vendor_settlements s
       where s.settlement_id = p_doc_id
         and s.vendor_id = qvm_new_apps.current_upload_vendor_id());
  elsif p_doc_kind in ('invoice', 'return') then
    v_ok := (qvm_new_apps.vendor_documents_list(null, null, null, null, 1, 0,
               p_doc_kind || ':' || p_doc_id))->'data'->'rows'->0 is not null;
  else
    return jsonb_build_object('status', false, 'message', 'نوع مستند غير معروف', 'data', null);
  end if;

  if not v_ok then
    return jsonb_build_object('status', false, 'message', 'المستند غير موجود', 'data', null);
  end if;

  insert into qvm_new_apps.vendor_document_notes
    (doc_kind, doc_id, body, visibility, author_side, author_id, attachment_url)
  values (p_doc_kind, p_doc_id, btrim(coalesce(p_body, '')), p_visibility, v_side,
          auth.uid(), p_attachment_url)
  returning note_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'note_id', v_id, 'notes', qvm_new_apps.vendor_notes_of(p_doc_kind, p_doc_id, v_side)));
end
$$;

-- vendor_notes_of is SECURITY INVOKER and deliberately not granted: it takes the reader's side as
-- an argument, so a caller that could reach it directly could pass the other side's and read their
-- private notes. It is only ever called from inside the definer functions above, where it runs with
-- their privileges and with a side those functions computed themselves.
revoke all on function qvm_new_apps.vendor_notes_of(text, bigint, text) from public;
revoke all on function qvm_new_apps.vendor_document_detail(text, bigint) from public;
revoke all on function qvm_new_apps.vendor_note_add(text, bigint, text, text, text) from public;
grant execute on function qvm_new_apps.vendor_document_detail(text, bigint),
                          qvm_new_apps.vendor_note_add(text, bigint, text, text, text)
  to authenticated, service_role;
