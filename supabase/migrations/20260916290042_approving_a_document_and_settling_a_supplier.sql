-- Approving a document, and paying a supplier for a set of them.
--
-- Two guards do most of the work, and both come from the design rather than from taste:
--
--   · An invoice cannot be approved while any line of its order is unreceived. The screen greys
--     the button and says «لا يمكن الاعتماد حتى يتم استلام جميع الأصناف»; this is the same rule on
--     the server, because a greyed button is a suggestion and a check is a rule.
--   · A settlement covers exactly one supplier. Not a convention — a bank transfer cannot be split
--     between two companies, so a request that mixed them could never be closed.
--
-- One deliberate difference from the design, stated so it can be overruled: cancelling a request
-- RELEASES its unpaid documents back to what they were. The mock says they «تصبح ملغاة», which
-- reads two ways — the membership ends, or the invoice itself does. Destroying an invoice because
-- a transfer was called off would erase a debt the supplier is still owed, so the membership is
-- what ends. Verified: closing a two-document request on one of them left the other «معتمدة» and
-- still owed.

create or replace function qvm_new_apps.vendor_document_approve(p_doc_kind text, p_doc_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_unreceived integer;
begin
  -- The vendor's own screen has no approve button; the check is here because the RPC is reachable
  -- with or without one.
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'الاعتماد من صلاحية المشتريات', 'data', null);
  end if;

  if p_doc_kind = 'invoice' then
    select count(*) into v_unreceived
      from qvm_new_apps.purchase_items pi
      join qvm_new_apps.purchase_invoice_attachments a
        on a.purchase_order_id = pi.purchase_order_id and a.attachment_id = p_doc_id
     where coalesce(pi.receipt_status, 'not_received') <> 'received';
    if v_unreceived > 0 then
      return jsonb_build_object('status', false, 'data', jsonb_build_object('unreceived', v_unreceived),
        'message', 'لا يمكن الاعتماد حتى يتم استلام جميع الأصناف');
    end if;
    update qvm_new_apps.purchase_invoice_attachments
       set approved_at = now(), approved_by = auth.uid()
     where attachment_id = p_doc_id and approved_at is null;
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

create or replace function qvm_new_apps.vendor_settlement_create(p_docs jsonb)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team    boolean := qvm_new_apps.is_qparts_team();
  v_vendor  integer := qvm_new_apps.current_upload_vendor_id();
  v_side    text := case when v_team then 'purchasing' else 'vendor' end;
  v_rows    jsonb;
  v_vendors integer[];
  v_net     numeric := 0;
  v_id      bigint;
  v_code    text;
  r         record;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Read each requested document back through the list, so its state, its amount and who may see
  -- it are decided by the same code the screen read them from.
  select coalesce(jsonb_agg(d), '[]'::jsonb) into v_rows
    from jsonb_array_elements(p_docs) as x
    cross join lateral (
      select d from jsonb_array_elements(
        (qvm_new_apps.vendor_documents_list(null, null, null, null, 200, 0))->'data'->'rows') as d
       where d->>'doc_kind' = x->>'doc_kind' and (d->>'doc_id')::bigint = (x->>'doc_id')::bigint
    ) k;

  if jsonb_array_length(v_rows) = 0 then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'لم يتم العثور على المستندات المحددة');
  end if;

  -- Only what is owed and unsettled. The mock says the same in an alert; here it is a refusal.
  if exists (select 1 from jsonb_array_elements(v_rows) d
              where d->>'state' not in ('approved', 'overdue', 'partial')) then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'طلب التسوية يشمل المستندات المعتمدة أو المتأخرة أو الجزئية فقط');
  end if;

  select array_agg(distinct (d->>'vendor_id')::integer) into v_vendors
    from jsonb_array_elements(v_rows) d;
  if array_length(v_vendors, 1) > 1 then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'لا يمكن ضمّ فواتير أكثر من مورد في طلب واحد — الفروع مختلفة مسموحة');
  end if;

  select coalesce(sum((d->>'signed_total')::numeric), 0) into v_net
    from jsonb_array_elements(v_rows) d;

  insert into qvm_new_apps.vendor_settlements
    (code, vendor_id, raised_by_side, status, net_amount, created_by)
  values ('STL-TEMP', v_vendors[1], v_side, 'pending', v_net, auth.uid())
  returning settlement_id into v_id;
  v_code := 'STL-' || lpad(v_id::text, 4, '0');
  update qvm_new_apps.vendor_settlements set code = v_code where settlement_id = v_id;

  for r in select (d->>'doc_kind') as k, (d->>'doc_id')::bigint as i,
                  (d->>'signed_total')::numeric as amt
             from jsonb_array_elements(v_rows) d
  loop
    -- The unique index refuses a document that is already in an open request; say which.
    begin
      insert into qvm_new_apps.vendor_settlement_items (settlement_id, doc_kind, doc_id, amount)
      values (v_id, r.k, r.i, r.amt);
    exception when unique_violation then
      raise exception 'المستند % مضموم بالفعل إلى طلب تسوية مفتوح', r.i;
    end;
  end loop;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'settlement_id', v_id, 'code', v_code, 'net_amount', v_net,
    'documents', jsonb_array_length(v_rows)));
end
$function$;

create or replace function qvm_new_apps.vendor_settlement_settle(
  p_settlement_id bigint, p_paid_doc_ids jsonb,
  p_bank_account text default null, p_transfer_ref text default null,
  p_receipt_url text default null, p_receipt_path text default null)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
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
        update qvm_new_apps.purchase_invoice_attachments
           set settled_amount = coalesce(settled_amount,0) + abs(r.amount), settled_at = now()
         where attachment_id = r.doc_id;
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

create or replace function qvm_new_apps.vendor_settlement_cancel(p_settlement_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_n integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  update qvm_new_apps.vendor_settlement_items
     set member_status = 'cancelled'
   where settlement_id = p_settlement_id and member_status = 'pending';
  get diagnostics v_n = row_count;
  update qvm_new_apps.vendor_settlements
     set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
   where settlement_id = p_settlement_id and status = 'pending';
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('released', v_n));
end
$function$;

revoke all on function qvm_new_apps.vendor_document_approve(text, bigint) from public;
revoke all on function qvm_new_apps.vendor_settlement_create(jsonb) from public;
revoke all on function qvm_new_apps.vendor_settlement_settle(bigint, jsonb, text, text, text, text) from public;
revoke all on function qvm_new_apps.vendor_settlement_cancel(bigint) from public;
grant execute on function qvm_new_apps.vendor_document_approve(text, bigint),
                          qvm_new_apps.vendor_settlement_create(jsonb),
                          qvm_new_apps.vendor_settlement_settle(bigint, jsonb, text, text, text, text),
                          qvm_new_apps.vendor_settlement_cancel(bigint)
  to authenticated, service_role;
