-- The six states a vendor document can be in, and the list both sides read.
--
--   غير مكتملة  incomplete — an invoice whose order still has an unreceived line. It cannot be
--                            approved, and saying «قيد الاعتماد» would invite someone to try.
--   قيد الاعتماد draft      — filed, nobody has approved it yet.
--   معتمدة       approved   — approved and owed, the due date has not arrived.
--   متأخرة       overdue    — approved and the due date has passed.
--   تسوية جزئية  partial    — part of it has been settled.
--   مسوّاة       settled    — settled in full.
--
-- None of these is a column, and «متأخرة» is why. It is «معتمدة» plus a date that has passed, so a
-- stored copy is wrong from the midnight after it is written until something rewrites it. What is
-- stored is only what a person decided — approved, and how much was settled — and the rest is
-- derived, so the list can never disagree with the calendar.
create or replace function qvm_new_apps.vendor_document_state(
  p_approved_at    timestamptz,
  p_cancelled_at   timestamptz,
  p_total          numeric,
  p_settled        numeric,
  p_issued_on      date,
  p_term_days      integer,
  p_all_received   boolean)
returns text
language sql
immutable
as $$
  select case
    when p_cancelled_at is not null                                   then 'cancelled'
    when coalesce(p_settled, 0) >= coalesce(p_total, 0)
         and coalesce(p_total, 0) > 0                                 then 'settled'
    when coalesce(p_settled, 0) > 0                                   then 'partial'
    when p_approved_at is null and p_all_received is false            then 'incomplete'
    when p_approved_at is null                                        then 'draft'
    when p_issued_on is not null
         and (p_issued_on + coalesce(p_term_days, 30)) < current_date then 'overdue'
    else 'approved'
  end;
$$;

-- ── The list ───────────────────────────────────────────────────────────────────────────────────
-- Invoices and credit notes together, because that is the question the screen asks: what is owed
-- to this supplier, net. A return is a negative row, not a separate page.
--
-- One function for both sides. The vendor sees their own documents and the buying team sees every
-- supplier's; that is the only difference, and putting it in two functions would be two places for
-- the same filter to drift.
--
-- Both unions read the branch and the awarded vendor through a LATERAL that takes ONE line of the
-- order. Joining the lines directly multiplied each document by the number of lines on its order —
-- a three-line order listed its invoice three times and counted its money three times with it.
create or replace function qvm_new_apps.vendor_documents_list(
  p_status   text default null,
  p_doc_type text default null,
  p_vendor   integer default null,
  p_search   text default null,
  p_limit    integer default 50,
  p_offset   integer default 0)
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
     where (p_status is null or p_status = '' or p_status = 'all' or d.state = p_status)
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

revoke all on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer) from public;
grant execute on function qvm_new_apps.vendor_documents_list(text, text, integer, text, integer, integer)
  to authenticated, service_role;
grant execute on function qvm_new_apps.vendor_document_state(timestamptz, timestamptz, numeric, numeric, date, integer, boolean)
  to authenticated, service_role;
