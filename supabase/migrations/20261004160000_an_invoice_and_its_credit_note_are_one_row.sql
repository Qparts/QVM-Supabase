-- An invoice and its credit note are one row.
--
-- A vendor credit note uploaded together with a purchase invoice is the same transaction read
-- twice: on the supplier-invoices page they showed as two rows, and the credit note's figures
-- were not even saved when it was filed alongside the invoice. Now:
--
--   * `vendor_creditnotes.invoice_group_id` names the invoice a credit note was filed with.
--     Notes already on file are linked to an invoice on the same purchase order uploaded within
--     five minutes of them — the only trace the old upload left.
--   * `file_vendor_creditnote` files a note on the purchase order the caller names (not the
--     order's newest), with its number, date, total and that link.
--   * `vendor_documents_list` folds a linked credit note into its invoice's row: `has_return`,
--     `return_total`, `return_codes`, `return_doc_ids`, `invoice_total`, and the row's `total`
--     and `signed_total` net the credit. The note's own row leaves the list. Asked for one
--     document by key, each document still stands alone, so settlements net and settle both.
--     `p_doc_type = 'invoice_return'` lists only such pairs.
--   * `vendor_document_detail` returns the linked notes (`returns`, each with its lines),
--     `return_total` and `net_total`.
--   * `vendor_document_approve` approves the linked notes with the invoice.

ALTER TABLE qvm_new_apps.vendor_creditnotes ADD COLUMN IF NOT EXISTS invoice_group_id uuid;
CREATE INDEX IF NOT EXISTS vendor_creditnotes_invoice_group_idx
  ON qvm_new_apps.vendor_creditnotes (invoice_group_id) WHERE invoice_group_id IS NOT NULL;

-- Link what was uploaded together before the link existed.
UPDATE qvm_new_apps.vendor_creditnotes cn
   SET invoice_group_id = l.invoice_group_id
  FROM (
    SELECT DISTINCT ON (cn2.vendor_creditnote_id) cn2.vendor_creditnote_id, a.invoice_group_id
      FROM qvm_new_apps.vendor_creditnotes cn2
      JOIN qvm_new_apps.purchase_invoice_attachments a
        ON a.purchase_order_id = cn2.purchase_order_id
       AND a.cancelled_at IS NULL
       AND abs(extract(epoch FROM (a.uploaded_at - cn2.uploaded_at))) <= 300
     WHERE cn2.invoice_group_id IS NULL
     ORDER BY cn2.vendor_creditnote_id, abs(extract(epoch FROM (a.uploaded_at - cn2.uploaded_at)))
  ) l
 WHERE l.vendor_creditnote_id = cn.vendor_creditnote_id;

CREATE OR REPLACE FUNCTION qvm_new_apps.file_vendor_creditnote(
  p_purchase_order_id bigint,
  p_file_url text,
  p_number text DEFAULT NULL,
  p_issued_on date DEFAULT NULL,
  p_total_amount numeric DEFAULT NULL,
  p_invoice_group_id uuid DEFAULT NULL,
  p_mode text DEFAULT 'add',
  p_uploaded_source text DEFAULT 'internal')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
-- Files a vendor credit note on the purchase order its lines sit on — named by the caller, never
-- guessed as «the order's newest purchase order» — with the figures the paper carries, and, when
-- it was uploaded together with an invoice, the invoice group it belongs with. `replace` rewrites
-- the purchase order's latest note; `add` files another.
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_orders WHERE purchase_order_id = p_purchase_order_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Purchase order not found');
  END IF;
  IF p_invoice_group_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.purchase_invoice_attachments a WHERE a.invoice_group_id = p_invoice_group_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'The invoice this credit note is filed with was not found');
  END IF;

  IF p_mode = 'replace' THEN
    SELECT vendor_creditnote_id INTO v_id
      FROM qvm_new_apps.vendor_creditnotes
     WHERE purchase_order_id = p_purchase_order_id AND cancelled_at IS NULL
     ORDER BY created_at DESC LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.vendor_creditnotes
      (purchase_order_id, vendor_creditnote_url, vendor_creditnote_number, uploaded_by, uploaded_at,
       uploaded_source, issued_on, total_amount, invoice_group_id)
    VALUES
      (p_purchase_order_id, p_file_url, NULLIF(btrim(p_number), ''), auth.uid(), now(),
       COALESCE(NULLIF(p_uploaded_source, ''), 'internal'), p_issued_on, p_total_amount, p_invoice_group_id)
    RETURNING vendor_creditnote_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.vendor_creditnotes
       SET vendor_creditnote_url = p_file_url,
           vendor_creditnote_number = COALESCE(NULLIF(btrim(p_number), ''), vendor_creditnote_number),
           uploaded_by = auth.uid(), uploaded_at = now(),
           uploaded_source = COALESCE(NULLIF(p_uploaded_source, ''), 'internal'),
           issued_on = COALESCE(p_issued_on, issued_on),
           total_amount = COALESCE(p_total_amount, total_amount),
           invoice_group_id = COALESCE(p_invoice_group_id, invoice_group_id)
     WHERE vendor_creditnote_id = v_id;
  END IF;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'vendor_creditnote_id', v_id, 'purchase_order_id', p_purchase_order_id);
END;
$function$;

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
           i.grp as invoice_group_id
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
           cn.invoice_group_id
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
           d.total as invoice_total,
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
       and (p_doc_key is not null or d.doc_kind <> 'return' or d.invoice_group_id is null
            or not exists (select 1 from qvm_new_apps.purchase_invoice_attachments a
                            where a.invoice_group_id = d.invoice_group_id))
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
            (to_jsonb(f) - 'n') || jsonb_build_object(
              -- The row's total is the invoice less the credit note filed with it; what is owed
              -- nets what the credit note already gave back.
              'total', f.total - f.return_total,
              'signed_total', f.signed_total - (f.return_total - f.return_settled))
            order by f.issued_on desc, f.doc_id desc), '[]'::jsonb) from filtered f),
         (select coalesce(max(n), 0) from filtered),
         (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb)
            from (select state, count(*) as n from docs group by state) k),
         (select jsonb_build_object(
            'total_overdue',   coalesce(sum(signed_total) filter (where state = 'overdue'), 0),
            'total_approved',  coalesce(sum(signed_total) filter (where state in ('approved','overdue')), 0),
            'total_documents', coalesce(sum(signed_total), 0),
            'total_settled',   coalesce(sum(settled), 0),
            'count',           count(*)) from docs),
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
    'net_total', coalesce((v_header->>'total')::numeric, 0) - v_return_total,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_document_approve(p_doc_kind text, p_doc_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_unreceived integer; v_grp uuid;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'الاعتماد من صلاحية المشتريات', 'data', null);
  end if;

  if p_doc_kind = 'invoice' then
    select invoice_group_id into v_grp
      from qvm_new_apps.purchase_invoice_attachments where attachment_id = p_doc_id;
    if v_grp is null then
      return jsonb_build_object('status', false, 'message', 'المستند غير موجود', 'data', null);
    end if;

    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
     where pi.purchase_order_id in (
             select a.purchase_order_id from qvm_new_apps.purchase_invoice_attachments a
              where a.invoice_group_id = v_grp)
       and coalesce(pi.receipt_status, 'not_received') <> 'received';
    if v_unreceived > 0 then
      return jsonb_build_object('status', false, 'data', jsonb_build_object('unreceived', v_unreceived),
        'message', 'لا يمكن الاعتماد حتى يتم استلام جميع الأصناف');
    end if;

    update qvm_new_apps.purchase_invoice_attachments
       set approved_at = now(), approved_by = auth.uid()
     where invoice_group_id = v_grp and approved_at is null;
    -- The credit note filed with the invoice is approved with it: one paper trail, one decision.
    update qvm_new_apps.vendor_creditnotes
       set approved_at = now(), approved_by = auth.uid()
     where invoice_group_id = v_grp and approved_at is null and cancelled_at is null;
  elsif p_doc_kind = 'return' then
    update qvm_new_apps.vendor_creditnotes
       set approved_at = now(), approved_by = auth.uid()
     where vendor_creditnote_id = p_doc_id and approved_at is null;
  else
    return jsonb_build_object('status', false, 'message', 'نوع مستند غير معروف', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('doc_kind', p_doc_kind, 'doc_id', p_doc_id));
end
$function$;
