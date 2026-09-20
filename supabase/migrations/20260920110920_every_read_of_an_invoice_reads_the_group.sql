-- Every read of an invoice reads the group, not the row.
--
-- The previous migration gave each piece of paper an id. This one makes the seven places that read
-- an invoice agree that the paper is the unit: the list, its items, the detail panel, approval,
-- settlement, and the statement. Leaving any one of them on the old grain would be worse than the
-- bug it replaces — half the screens saying 3,000 and half saying 6,000.
--
-- Three aggregate choices worth stating, because they only look arbitrary:
--
--   total    max(), not sum(). Each row carries the invoice's FULL total — the uploader writes the
--            same figure to every order it covers. Summing them is precisely the double count.
--   issued   min(). The paper has one date; the rows are copies of it, and min() is stable if one
--            copy was filed without one.
--   po_text  every order, joined. «PO-13558, PO-13559» is the honest answer to «which order is this
--            invoice for», and a single id would silently pick one and hide the other.
create or replace function qvm_new_apps.vendor_documents_list(
  p_status   text default null,
  p_doc_type text default null,
  p_vendor   integer default null,
  p_search   text default null,
  p_limit    integer default 50,
  p_offset   integer default 0,
  p_doc_key  text default null,
  p_party    text default null,
  p_po       text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
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
    -- One row per piece of paper.
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
             -- Across every order the paper covers, not just one of them.
             not exists (select 1 from qvm_new_apps.purchase_items pi
                          where pi.purchase_order_id = any (i.po_ids)
                            and coalesce(pi.receipt_status, 'not_received') <> 'received')) as state,
           st.code as settlement_code, st.transfer_ref, i.match_pct, i.uploaded_at
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
    -- A credit note has no payment term: it is owed back the moment it exists.
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
           st.code, st.transfer_ref, null, cn.created_at
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
    select d.*, count(*) over () as n from docs d
     where (p_doc_key is null or d.doc_key = p_doc_key)
       and (p_status is null or p_status = '' or p_status = 'all' or d.state = p_status)
       and (p_doc_type is null or p_doc_type = '' or p_doc_type = 'all' or d.doc_kind = p_doc_type)
       and (p_vendor is null or d.vendor_id = p_vendor)
       and (p_party is null or p_party = '' or d.party = p_party)
       -- The column filter matches an order inside a multi-order invoice, not only one that
       -- happens to be the whole of it.
       and (p_po is null or p_po = '' or d.po_text = p_po or d.po_text like '%' || p_po || '%')
       and (v_q is null or coalesce(d.code,'') ilike '%'||v_q||'%' or d.po_text ilike '%'||v_q||'%'
            or coalesce(d.vendor_name,'') ilike '%'||v_q||'%'
            or coalesce(d.party,'') ilike '%'||v_q||'%')
     order by d.issued_on desc, d.doc_id desc
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select coalesce(jsonb_agg(to_jsonb(f) - 'n' order by f.issued_on desc, f.doc_id desc), '[]'::jsonb) from filtered f),
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
            -- One entry per order, split back out of the joined label, so the dropdown offers an
            -- order rather than a combination that only one invoice happens to have.
            'pos',     (select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
                          from docs, lateral unnest(string_to_array(po_text, ', ')) p
                         where po_text is not null)))
    into v_rows, v_total, v_counts, v_kpi, v_facets;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts, 'kpi', v_kpi, 'facets', v_facets,
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'vendor_id', v_vendor));
end
$$;

-- The lines of an invoice are the lines of every order it covers.
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
        -- Every attachment row of the same paper, so an invoice spanning two orders shows both
        -- orders' lines instead of the first one's.
        join qvm_new_apps.purchase_invoice_attachments a
          on a.purchase_order_id = pi.purchase_order_id
         and a.invoice_group_id = (select g.invoice_group_id
                                     from qvm_new_apps.purchase_invoice_attachments g
                                    where g.attachment_id = p_doc_id)
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
        left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        left join qvm_new_apps.list_data ld on ld.list_data_id = ci.final_brand_class
        left join lateral (
          select qvi.cost from qvm_new_apps.quotation_vendor_items qvi
           where qvi.cost_id = coalesce(pi.cost_id, qi.cost_id)
           order by qvi.cost_id limit 1) qvi on true) k)
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

-- Approving the paper approves every row it produced. Approving one of them would leave the same
-- invoice half approved, which no screen has a way to show and no rule has a way to resolve.
create or replace function qvm_new_apps.vendor_document_approve(p_doc_kind text, p_doc_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
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

-- Settling the paper marks every row it produced. Same reason as approval: the invoice is the
-- unit, and a half-settled invoice is a state the list would read as «partial» forever.
do $do$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.vendor_settlement_settle(bigint,jsonb,text,text,text,text)'::regprocedure);
  v_old text := '      if r.doc_kind = ''invoice'' then
        update qvm_new_apps.purchase_invoice_attachments
           set settled_amount = coalesce(settled_amount,0) + abs(r.amount), settled_at = now()
         where attachment_id = r.doc_id;';
  v_new text := '      if r.doc_kind = ''invoice'' then
        -- Every row of the paper, not the one the request happens to name.
        update qvm_new_apps.purchase_invoice_attachments
           set settled_amount = coalesce(settled_amount,0) + abs(r.amount), settled_at = now()
         where invoice_group_id = (select g.invoice_group_id
                                     from qvm_new_apps.purchase_invoice_attachments g
                                    where g.attachment_id = r.doc_id);';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_settle: expected the invoice update once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- The detail panel: the file of the first row, the unreceived count across the whole paper.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_document_detail(text,bigint)'::regprocedure);
  v_old text := '    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
      join qvm_new_apps.purchase_invoice_attachments a
        on a.purchase_order_id = pi.purchase_order_id and a.attachment_id = p_doc_id
     where coalesce(pi.receipt_status, ''not_received'') <> ''received'';';
  v_new text := '    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
     where pi.purchase_order_id in (
             select a.purchase_order_id from qvm_new_apps.purchase_invoice_attachments a
              where a.invoice_group_id = (select g.invoice_group_id
                                            from qvm_new_apps.purchase_invoice_attachments g
                                           where g.attachment_id = p_doc_id))
       and coalesce(pi.receipt_status, ''not_received'') <> ''received'';';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_document_detail: expected the unreceived count once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- The statement counts the paper once.
--
-- It read purchase_invoice_attachments directly, so the same invoice contributed a line per order
-- — the double count again, this time on a running balance where it is hardest to spot.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_statement(integer,date,date)'::regprocedure);
  v_old text := '    select ''invoice''::text as kind, a.attachment_id as ref_id,
           ''invoice:'' || a.attachment_id as doc_key,
           nullif(a.invoice_number,'''') as ref,
           coalesce(a.issued_on, a.uploaded_at::date) as line_date,
           coalesce(a.total_amount, 0) as amount,
           ''PO-'' || a.purchase_order_id as po_text,
           a.approved_at
      from qvm_new_apps.purchase_invoice_attachments a
      join lateral (
        select qvi.vendor_id
          from qvm_new_apps.confirmed_items ci
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
         where ci.confirmed_order_id = a.confirmed_order_id
         order by ci.confirmed_item_id limit 1) v on true
     where v.vendor_id = v_vendor
       and a.approved_at is not null
       and a.cancelled_at is null';
  v_new text := '    select ''invoice''::text as kind, i.doc_id as ref_id,
           ''invoice:'' || i.doc_id as doc_key,
           i.code as ref,
           i.issued_on as line_date,
           i.total as amount,
           ''PO-'' || array_to_string(i.po_ids, '', PO-'') as po_text,
           i.approved_at
      from (select a.invoice_group_id,
                   min(a.attachment_id) as doc_id,
                   max(nullif(a.invoice_number,'''')) as code,
                   min(coalesce(a.issued_on, a.uploaded_at::date)) as issued_on,
                   max(coalesce(a.total_amount, 0)) as total,
                   max(a.approved_at) as approved_at,
                   max(a.cancelled_at) as cancelled_at,
                   min(a.confirmed_order_id) as confirmed_order_id,
                   array_agg(distinct a.purchase_order_id) as po_ids
              from qvm_new_apps.purchase_invoice_attachments a
             group by a.invoice_group_id) i
      join lateral (
        select qvi.vendor_id
          from qvm_new_apps.confirmed_items ci
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
         where ci.confirmed_order_id = i.confirmed_order_id
         order by ci.confirmed_item_id limit 1) v on true
     where v.vendor_id = v_vendor
       and i.approved_at is not null
       and i.cancelled_at is null';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_statement: expected the invoice branch once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
