-- The supplier's statement: what we owe them, and everything that moved it.
--
-- The vendor portal has had a «كشف الحساب والمدفوعات» tab since it was built, filled by
-- buildMockLedger(). It has never shown a real number.
--
-- Three kinds of line, and one rule about which of them count:
--
--   فاتورة   an approved invoice          — we owe more
--   مرتجع    an approved credit note      — we owe less
--   سداد     a settled settlement request — we owe less, because the money left
--
-- Only approved. An invoice that has been filed but not approved is a claim, not a debt: the
-- buying side has not yet agreed the parts arrived and the figures are right. Putting it on the
-- statement would tell a supplier they are owed money nobody has agreed to. It appears the moment
-- it is approved, which is what makes approval worth doing.
--
-- It appears AT ITS OWN DATE, not at the date it was approved. An invoice from the 3rd approved on
-- the 20th belongs on the 3rd — that is when the obligation arose, and it is the date both sides
-- will read off the paper when they argue about it. The consequence is that approving an old
-- invoice inserts a line into the past and moves every balance after it. That is correct, and it
-- is also why the closing balance is the number to trust rather than any figure someone wrote down
-- from this screen last week.
--
-- No double counting between a credit note and the payment that followed it. The transfer is
-- recorded as the cash that actually left — the net of the documents it covered — so a return
-- appears once as a credit and once inside a smaller payment, and a request that covered exactly
-- its documents brings the balance to zero.
--
-- The running balance is not returned. The page adds it up as it draws, the same way the customer
-- statement does: a stored balance and the rows it came from disagree the first time anyone edits
-- one of them. What IS returned is the opening balance, because that cannot be derived from rows
-- the page was not given.
create or replace function qvm_new_apps.vendor_statement(
  p_vendor integer default null,
  p_from   date default null,
  p_to     date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team    boolean := qvm_new_apps.is_qparts_team();
  v_mine    integer := qvm_new_apps.current_upload_vendor_id();
  v_vendor  integer;
  v_lines   jsonb;
  v_opening numeric := 0;
  v_totals  jsonb;
begin
  if not v_team and v_mine is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- A supplier reads their own, whatever they ask for. The buying team picks one; without a pick
  -- there is no statement to draw, because a statement is a running balance with one counterparty
  -- and summing several of them produces a number that is nobody's.
  v_vendor := case when v_team then p_vendor else v_mine end;
  if v_vendor is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'lines', '[]'::jsonb, 'opening', 0, 'vendor_id', null,
      'side', case when v_team then 'purchasing' else 'vendor' end,
      'totals', jsonb_build_object('invoiced', 0, 'returned', 0, 'paid', 0, 'closing', 0),
      'needs_vendor', true));
  end if;

  with lines as (
    select 'invoice'::text as kind, a.attachment_id as ref_id,
           'invoice:' || a.attachment_id as doc_key,
           coalesce(nullif(a.invoice_number,''), 'INV-' || a.attachment_id) as ref,
           coalesce(a.issued_on, a.uploaded_at::date) as line_date,
           coalesce(a.total_amount, 0) as amount,
           'PO-' || a.purchase_order_id as po_text,
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
       and a.cancelled_at is null
    union all
    select 'return', cn.vendor_creditnote_id,
           'return:' || cn.vendor_creditnote_id,
           coalesce(nullif(cn.vendor_creditnote_number,''), 'RET-' || cn.vendor_creditnote_id),
           coalesce(cn.issued_on, cn.created_at::date),
           -coalesce(cn.total_amount, 0),
           'PO-' || cn.purchase_order_id,
           cn.approved_at
      from qvm_new_apps.vendor_creditnotes cn
      join lateral (
        select qvi.vendor_id
          from qvm_new_apps.purchase_items pi2
          join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi2.confirmed_item_id
          join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
          join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
         where pi2.purchase_order_id = cn.purchase_order_id
         order by pi2.confirmed_item_id limit 1) v on true
     where v.vendor_id = v_vendor
       and cn.approved_at is not null
       and cn.cancelled_at is null
    union all
    -- The cash that left, dated the day it left. Summed from the members the transfer actually
    -- covered rather than from the request's net_amount, which was the figure at the time it was
    -- raised and may have included documents the transfer went on to release.
    select 'payment', s.settlement_id,
           'settlement:' || s.settlement_id,
           s.code,
           s.settled_at::date,
           -coalesce((select sum(i.amount) from qvm_new_apps.vendor_settlement_items i
                       where i.settlement_id = s.settlement_id and i.member_status = 'settled'), 0),
           s.transfer_ref,
           s.settled_at
      from qvm_new_apps.vendor_settlements s
     where s.vendor_id = v_vendor
       and s.status = 'settled'
       and s.settled_at is not null
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
       'kind', l.kind, 'ref_id', l.ref_id, 'doc_key', l.doc_key, 'ref', l.ref,
       'line_date', l.line_date, 'amount', l.amount, 'po_text', l.po_text,
       'approved_at', l.approved_at)
     order by l.line_date, l.kind, l.ref_id), '[]'::jsonb)
       from lines l
      where (p_from is null or l.line_date >= p_from)
        and (p_to is null or l.line_date <= p_to)),
    (select coalesce(sum(l.amount), 0) from lines l
      where p_from is not null and l.line_date < p_from),
    (select jsonb_build_object(
       'invoiced', coalesce(sum(amount) filter (where kind = 'invoice'), 0),
       'returned', -coalesce(sum(amount) filter (where kind = 'return'), 0),
       'paid',     -coalesce(sum(amount) filter (where kind = 'payment'), 0),
       -- Closing is over everything, never only the window on screen: «what do we owe this
       -- supplier» has one answer, and a date filter is not allowed to change it.
       'closing',  coalesce(sum(amount), 0)) from lines)
  into v_lines, v_opening, v_totals;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'lines', v_lines, 'opening', v_opening, 'totals', v_totals,
    'vendor_id', v_vendor,
    'side', case when v_team then 'purchasing' else 'vendor' end,
    'needs_vendor', false));
end
$$;

revoke all on function qvm_new_apps.vendor_statement(integer, date, date) from public;
grant execute on function qvm_new_apps.vendor_statement(integer, date, date)
  to authenticated, service_role;
