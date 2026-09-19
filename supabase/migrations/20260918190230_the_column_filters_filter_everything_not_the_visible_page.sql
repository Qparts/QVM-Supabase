-- The per-column filters become real filters.
--
-- The design puts a select under «الفرع/الورشة» and under «رقم الطلب». The list paginates on the
-- server, so a screen that applied those in the browser would filter the fifty rows it happens to
-- be holding and present the result as the answer — «3 documents for فرع جدة» when there are
-- eleven. A filter that only covers what is already on screen is worse than no filter, because it
-- looks like it worked.
--
-- So both become arguments, and the options they offer come back with the rows: `parties` and
-- `pos`, collected over the whole scoped set rather than the page. A dropdown built from the
-- visible page would be missing exactly the values you are looking for.
--
-- Dropped and recreated, not replaced: the argument list changes, and CREATE OR REPLACE with a new
-- signature leaves the old function standing beside the new one for callers to keep hitting.
--
-- This is the whole body rather than another text patch on top of two earlier ones — including the
-- member_status <> 'cancelled' fix from 20260916310042, which is folded in here. Three successive
-- patches against the same function is how the file stops describing what is actually running.
drop function if exists qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer, text);

create or replace function qvm_new_apps.vendor_documents_list(
  p_status   text default null,
  p_doc_type text default null,
  p_vendor   integer default null,
  p_search   text default null,
  p_limit    integer default 50,
  p_offset   integer default 0,
  -- 'invoice:87' — the pair that identifies one row of the union.
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
      -- Only a membership that is still live. A document released when a request closed without it
      -- is owed again and belongs to no request.
      left join lateral (
        select s.code, s.transfer_ref from qvm_new_apps.vendor_settlement_items si
          join qvm_new_apps.vendor_settlements s on s.settlement_id = si.settlement_id
         where si.doc_kind = 'invoice' and si.doc_id = a.attachment_id
           and si.member_status <> 'cancelled'
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
       and (p_po is null or p_po = '' or d.po_text = p_po)
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
            'count',           count(*)) from docs),
         -- The dropdowns' own options, over the whole scope. Built from the page they would be
         -- missing exactly the value being looked for.
         (select jsonb_build_object(
            'vendors', (select coalesce(jsonb_agg(distinct jsonb_build_object(
                          'vendor_id', vendor_id, 'vendor_name', vendor_name)), '[]'::jsonb)
                          from docs where vendor_id is not null),
            'parties', (select coalesce(jsonb_agg(distinct party), '[]'::jsonb)
                          from docs where party is not null),
            'pos',     (select coalesce(jsonb_agg(distinct po_text), '[]'::jsonb)
                          from docs where po_text is not null)))
    into v_rows, v_total, v_counts, v_kpi, v_facets;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts, 'kpi', v_kpi, 'facets', v_facets,
    -- The screen needs to know which side it is drawing for; it must not decide that itself.
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'vendor_id', v_vendor));
end
$$;

revoke all on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer, text, text, text) from public;
grant execute on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer, text, text, text)
  to authenticated, service_role;

-- Three callers pass the doc_key positionally and must be told the shape moved. Each is rewritten
-- to name its arguments, so the next column filter added here does not break them again.
do $do$
declare
  v_names text[] := array['vendor_settlement_create', 'vendor_document_detail',
                          'vendor_note_add', 'vendor_settlement_detail'];
  v_old text := 'qvm_new_apps.vendor_documents_list(null, null, null, null, 1, 0,';
  v_new text := 'qvm_new_apps.vendor_documents_list(p_limit => 1, p_doc_key =>';
  v_def text;
  v_hits integer;
  v_fn text;
  v_oid oid;
begin
  foreach v_fn in array v_names loop
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'qvm_new_apps' and p.proname = v_fn;
    v_def := pg_get_functiondef(v_oid);
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
    if v_hits <> 1 then
      raise exception '%: expected one positional call to vendor_documents_list, found %', v_fn, v_hits;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$do$;
