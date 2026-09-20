-- A payment to a supplier can exist before anyone decides which invoices it covers.
--
-- Until now the only way money left was a settlement request: pick documents, transfer, done. Real
-- payments do not always arrive in that order — a transfer goes out on account, a round number is
-- sent against a running balance, and which invoices it clears is worked out afterwards. There was
-- nowhere to record that, so it either did not get recorded or it got forced into a request that
-- misstated what it was for.
--
-- This does NOT add a payments table. Two tables answering «how much have we paid this supplier»
-- is how two answers appear, and money is the worst place to have two. An on-account payment is a
-- settlement that was born settled and has no members yet; allocating it adds members. Same row,
-- same statement line, same place the cash is recorded.
--
-- Three columns carry what a request never needed to say:
--
--   paid_amount  the cash that actually left. A request's was always implied by its settled
--                members; an on-account payment states it up front, and the difference between it
--                and what has been allocated is the whole point of the new column on screen.
--   paid_on      the day it left, which for a back-dated transfer is not the day it was typed in.
--   method       cash, transfer, cheque — free text, because this is a note to the person
--                reconciling a bank statement, not something the system branches on.
alter table qvm_new_apps.vendor_settlements
  add column if not exists paid_amount numeric,
  add column if not exists paid_on     date,
  add column if not exists method      text,
  add column if not exists is_adhoc    boolean not null default false;

comment on column qvm_new_apps.vendor_settlements.paid_amount is
  'The cash that actually left. Null on a request still pending — nothing has left yet.';
comment on column qvm_new_apps.vendor_settlements.is_adhoc is
  'True for a payment recorded on account, before anyone said which invoices it covers.';

-- Existing settled requests: what left was the sum of the members that were settled, not the
-- net_amount they were raised for. Those two already diverge on dev — STL-0001 was raised for
-- 4,025 and paid 3,795 when one of its documents was released — and the paid figure is the one
-- that belongs in this column.
update qvm_new_apps.vendor_settlements s
   set paid_amount = (select coalesce(sum(i.amount), 0)
                        from qvm_new_apps.vendor_settlement_items i
                       where i.settlement_id = s.settlement_id and i.member_status = 'settled'),
       paid_on = coalesce(s.paid_on, s.settled_at::date)
 where s.status = 'settled' and s.paid_amount is null;

-- ── Recording one ──────────────────────────────────────────────────────────────────────────────
-- Born settled, because the money has already gone. A payment nobody has allocated is not a draft;
-- it is a fact about a bank account, and leaving it "pending" would let the statement pretend the
-- balance had not moved.
create or replace function qvm_new_apps.vendor_payment_record(
  p_vendor_id    integer,
  p_amount       numeric,
  p_paid_on      date default null,
  p_method       text default null,
  p_reference    text default null,
  p_receipt_url  text default null,
  p_receipt_path text default null,
  p_bank_account text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_id bigint; v_code text;
begin
  -- Money leaving is the buying side's act, the same rule that guards confirming a transfer.
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تسجيل الدفعات من صلاحية المشتريات');
  end if;
  if p_vendor_id is null or not exists (
       select 1 from qvm_new_apps.vendors where vendor_id = p_vendor_id) then
    return jsonb_build_object('status', false, 'message', 'المورد غير موجود', 'data', null);
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الدفعة يجب أن تكون أكبر من صفر', 'data', null);
  end if;
  -- A payment dated in the future has not happened. Same rule as an invoice's date, same reason:
  -- the statement would carry a balance movement that has not occurred.
  if coalesce(p_paid_on, current_date) > current_date then
    return jsonb_build_object('status', false, 'message', 'تاريخ الدفعة لا يمكن أن يكون في المستقبل', 'data', null);
  end if;

  insert into qvm_new_apps.vendor_settlements
    (code, vendor_id, raised_by_side, status, net_amount, paid_amount, paid_on, method,
     transfer_ref, receipt_url, receipt_path, bank_account, is_adhoc,
     created_by, created_at, settled_by, settled_at)
  values ('PAY-TEMP', p_vendor_id, 'purchasing', 'settled', p_amount, p_amount,
          coalesce(p_paid_on, current_date), nullif(btrim(coalesce(p_method,'')), ''),
          nullif(btrim(coalesce(p_reference,'')), ''), p_receipt_url, p_receipt_path,
          nullif(btrim(coalesce(p_bank_account,'')), ''), true,
          auth.uid(), now(), auth.uid(), now())
  returning settlement_id into v_id;

  -- PAY-, not STL-: a reader should be able to tell an on-account payment from a request that was
  -- raised against named documents without opening either.
  v_code := 'PAY-' || lpad(v_id::text, 4, '0');
  update qvm_new_apps.vendor_settlements set code = v_code where settlement_id = v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'settlement_id', v_id, 'code', v_code, 'paid_amount', p_amount));
end
$$;

-- ── Allocating it ──────────────────────────────────────────────────────────────────────────────
-- The whole allocation is replaced each time, not added to. An editor that shows every invoice
-- with an amount box and then only ADDS what you typed cannot express «actually, less than I said
-- last time», and the only way back would be a negative number.
--
-- Each document's settled_amount is then recomputed from all of its settled memberships rather
-- than incremented. Incrementing is right exactly once and wrong on every re-allocation, and the
-- error compounds silently in a column nobody reads directly.
create or replace function qvm_new_apps.vendor_payment_allocate(
  p_settlement_id bigint,
  p_allocations   jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_vendor    integer;
  v_paid      numeric;
  v_status    text;
  v_requested numeric := 0;
  v_touched   bigint[];
  r           record;
  v_owed      numeric;
  v_doc       jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تخصيص الدفعات من صلاحية المشتريات');
  end if;

  select vendor_id, coalesce(paid_amount, 0), status
    into v_vendor, v_paid, v_status
    from qvm_new_apps.vendor_settlements where settlement_id = p_settlement_id;
  if v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'الدفعة غير موجودة', 'data', null);
  end if;
  if v_status <> 'settled' then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'لا يمكن التخصيص إلا لدفعة تم سدادها');
  end if;

  select coalesce(sum((x->>'amount')::numeric), 0) into v_requested
    from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) x;
  if v_requested > v_paid then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'المبلغ المخصَّص أكبر من قيمة الدفعة');
  end if;

  -- Remember which documents this payment used to touch, so releasing one recomputes it too.
  select coalesce(array_agg(distinct doc_id), '{}') into v_touched
    from qvm_new_apps.vendor_settlement_items where settlement_id = p_settlement_id;

  delete from qvm_new_apps.vendor_settlement_items where settlement_id = p_settlement_id;

  for r in select (x->>'doc_kind') as kind, (x->>'doc_id')::bigint as id,
                  (x->>'amount')::numeric as amt
             from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) x
            where (x->>'amount')::numeric > 0
  loop
    -- Read what is owed through the list, so «how much is left on this invoice» is the same
    -- answer the screen showed — including this payment's own previous share, which the delete
    -- above has already given back.
    v_doc := (qvm_new_apps.vendor_documents_list(p_limit => 1,
               p_doc_key => r.kind || ':' || r.id))->'data'->'rows'->0;
    if v_doc is null then
      raise exception 'المستند % غير موجود', r.id;
    end if;
    v_owed := abs((v_doc->>'signed_total')::numeric);
    if r.amt > v_owed then
      raise exception 'المبلغ المخصَّص للمستند % أكبر من المتبقي عليه', coalesce(v_doc->>'code', r.id::text);
    end if;

    insert into qvm_new_apps.vendor_settlement_items
      (settlement_id, doc_kind, doc_id, amount, member_status)
    values (p_settlement_id, r.kind, r.id, r.amt, 'settled');

    v_touched := v_touched || r.id;
  end loop;

  -- Recompute, never increment.
  update qvm_new_apps.purchase_invoice_attachments a
     set settled_amount = coalesce((
           select sum(i.amount)
             from qvm_new_apps.vendor_settlement_items i
             join qvm_new_apps.vendor_settlements s on s.settlement_id = i.settlement_id
            where i.doc_kind = 'invoice' and i.member_status = 'settled'
              and s.status = 'settled'
              and i.doc_id in (select g.attachment_id
                                 from qvm_new_apps.purchase_invoice_attachments g
                                where g.invoice_group_id = a.invoice_group_id)), 0)
   where a.invoice_group_id in (
           select g.invoice_group_id from qvm_new_apps.purchase_invoice_attachments g
            where g.attachment_id = any (v_touched));

  update qvm_new_apps.vendor_creditnotes cn
     set settled_amount = coalesce((
           select sum(i.amount)
             from qvm_new_apps.vendor_settlement_items i
             join qvm_new_apps.vendor_settlements s on s.settlement_id = i.settlement_id
            where i.doc_kind = 'return' and i.doc_id = cn.vendor_creditnote_id
              and i.member_status = 'settled' and s.status = 'settled'), 0)
   where cn.vendor_creditnote_id = any (v_touched);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'settlement_id', p_settlement_id, 'allocated', v_requested,
    'unallocated', v_paid - v_requested));
end
$$;

revoke all on function qvm_new_apps.vendor_payment_record(integer, numeric, date, text, text, text, text, text) from public;
revoke all on function qvm_new_apps.vendor_payment_allocate(bigint, jsonb) from public;
grant execute on function qvm_new_apps.vendor_payment_record(integer, numeric, date, text, text, text, text, text),
                          qvm_new_apps.vendor_payment_allocate(bigint, jsonb)
  to authenticated, service_role;
