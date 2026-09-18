-- A document needs a name the screen can hold on to, and the list needs to be able to return one.
--
-- Two problems, one cause. The rows the list returns are a union of two tables, so `doc_id` alone
-- is not unique across them — invoice 12 and return 12 are different documents with the same id.
-- Anything that wants to point at one row (a React key, a checkbox, «open this one») has to carry
-- the pair, and every caller was about to re-derive it its own way.
--
-- And there was no way to ask for a single document at all. vendor_settlement_create worked around
-- that by pulling the first 200 rows and searching them in memory: a settlement raised against
-- document 201 would have been told it did not exist. The detail screen would have needed the same
-- workaround with the same hole.
--
-- So: every row now carries `doc_key` = 'invoice:87', and the list takes p_doc_key to return
-- exactly that row. The detail screen and the settlement builder both read their document through
-- the same function the table read it from — one place decides a document's state, its money and
-- who may see it, which is the only way those three can never disagree.
--
-- The counts and KPI block deliberately still describe the whole scoped set, not the filtered page.
-- They are the map above the table; a map that redraws itself when you open one document is not a
-- map.
--
-- Dropped and recreated rather than CREATE OR REPLACE: the argument list changes, and a replace
-- with a new signature does not replace anything — it leaves the old function in place beside the
-- new one, and callers keep reaching the stale copy.
drop function if exists qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer);

create or replace function qvm_new_apps.vendor_documents_list(
  p_status   text default null,
  p_doc_type text default null,
  p_vendor   integer default null,
  p_search   text default null,
  p_limit    integer default 50,
  p_offset   integer default 0,
  -- 'invoice:87' — the pair that identifies one row of the union.
  p_doc_key  text default null)
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
  v_rows jsonb; v_total bigint; v_counts jsonb; v_kpi jsonb;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with docs as (
    select 'invoice'::text as doc_kind, a.attachment_id as doc_id,
           'invoice:' || a.attachment_id as doc_key,
           coalesce(nullif(a.invoice_number,''), 'INV-' || a.attachment_id) as code,
           v.vendor_id, v.vendor_name, coalesce(cb.branch_name, '—') as party,
           'PO-' || a.purchase_order_id as po_text,
           coalesce(a.issued_on, a.uploaded_at::date) as issued_on,
           a.payment_term_days as term_days,
           coalesce(a.issued_on, a.uploaded_at::date) + coalesce(a.payment_term_days, 30) as due_on,
           coalesce(a.total_amount, 0) as total, coalesce(a.settled_amount, 0) as settled,
           coalesce(a.total_amount, 0) - coalesce(a.settled_amount, 0) as signed_total,
           qvm_new_apps.vendor_document_state(
             a.approved_at, a.cancelled_at, a.total_amount, a.settled_amount,
             coalesce(a.issued_on, a.uploaded_at::date), a.payment_term_days,
             not exists (select 1 from qvm_new_apps.purchase_items pi
                          where pi.purchase_order_id = a.purchase_order_id
                            and coalesce(pi.receipt_status, 'not_received') <> 'received')) as state,
           st.code as settlement_code, st.transfer_ref, a.match_pct, a.uploaded_at
      from qvm_new_apps.purchase_invoice_attachments a
      left join lateral (
        select cb.branch_name, vv.vendor_id, vv.vendor_name
          from qvm_new_apps.confirmed_items ci
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
          left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
          left join qvm_new_apps.vendors vv on vv.vendor_id = qvi.vendor_id
         where ci.confirmed_order_id = a.confirmed_order_id
         order by ci.confirmed_item_id limit 1) v on true
      left join lateral (select v.branch_name) cb(branch_name) on true
      left join lateral (
        select s.code, s.transfer_ref from qvm_new_apps.vendor_settlement_items si
          join qvm_new_apps.vendor_settlements s on s.settlement_id = si.settlement_id
         where si.doc_kind = 'invoice' and si.doc_id = a.attachment_id
         order by si.item_id desc limit 1) st on true
     where (v_team or v.vendor_id = v_vendor)
    union all
    -- A credit note has no payment term: it is owed back the moment it exists.
    select 'return', cn.vendor_creditnote_id,
           'return:' || cn.vendor_creditnote_id,
           coalesce(nullif(cn.vendor_creditnote_number,''), 'RET-' || cn.vendor_creditnote_id),
           v.vendor_id, v.vendor_name, coalesce(cb.branch_name, '—'),
           'PO-' || cn.purchase_order_id,
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
         order by si.item_id desc limit 1) st on true
     where (v_team or v.vendor_id = v_vendor)
  ), filtered as (
    select d.*, count(*) over () as n from docs d
     where (p_doc_key is null or d.doc_key = p_doc_key)
       and (p_status is null or p_status = '' or p_status = 'all' or d.state = p_status)
       and (p_doc_type is null or p_doc_type = '' or p_doc_type = 'all' or d.doc_kind = p_doc_type)
       and (p_vendor is null or d.vendor_id = p_vendor)
       and (v_q is null or d.code ilike '%'||v_q||'%' or d.po_text ilike '%'||v_q||'%'
            or coalesce(d.vendor_name,'') ilike '%'||v_q||'%'
            or coalesce(d.party,'') ilike '%'||v_q||'%')
     order by d.issued_on desc, d.doc_id desc
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select coalesce(jsonb_agg(to_jsonb(f) - 'n' order by f.issued_on desc, f.doc_id desc), '[]'::jsonb) from filtered f),
         (select coalesce(max(n), 0) from filtered),
         -- The chips count the whole set, not the page. A map that changes when you turn the page
         -- is not a map.
         (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb)
            from (select state, count(*) as n from docs group by state) k),
         (select jsonb_build_object(
            'total_overdue',   coalesce(sum(signed_total) filter (where state = 'overdue'), 0),
            'total_approved',  coalesce(sum(signed_total) filter (where state in ('approved','overdue')), 0),
            'total_documents', coalesce(sum(signed_total), 0),
            'total_settled',   coalesce(sum(settled), 0),
            'count',           count(*)) from docs)
    into v_rows, v_total, v_counts, v_kpi;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts, 'kpi', v_kpi,
    -- The screen needs to know which side it is drawing for; it must not decide that itself.
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'vendor_id', v_vendor));
end
$$;

revoke all on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer, text) from public;
grant execute on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer, text)
  to authenticated, service_role;

-- And the settlement builder stops paging through the list to find what it was handed.
--
-- It still reads each document through vendor_documents_list rather than off the table, because
-- the rules it enforces — is this owed, whose is it, how much is left — are that function's
-- answers. It just asks for the one row now instead of the first two hundred and searching them.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_settlement_create(jsonb)'::regprocedure);
  v_old text := '  select coalesce(jsonb_agg(d), ''[]''::jsonb) into v_rows
    from jsonb_array_elements(p_docs) as x
    cross join lateral (
      select d from jsonb_array_elements(
        (qvm_new_apps.vendor_documents_list(null, null, null, null, 200, 0))->''data''->''rows'') as d
       where d->>''doc_kind'' = x->>''doc_kind'' and (d->>''doc_id'')::bigint = (x->>''doc_id'')::bigint
    ) k;';
  v_new text := '  select coalesce(jsonb_agg(k.d), ''[]''::jsonb) into v_rows
    from jsonb_array_elements(p_docs) as x
    cross join lateral (
      select (qvm_new_apps.vendor_documents_list(null, null, null, null, 1, 0,
                (x->>''doc_kind'') || '':'' || (x->>''doc_id'')))->''data''->''rows''->0 as d
    ) k
   where k.d is not null;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_create: expected the read-back block exactly once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
