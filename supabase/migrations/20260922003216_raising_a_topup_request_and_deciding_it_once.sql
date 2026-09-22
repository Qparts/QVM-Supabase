-- Raising a top-up request, and deciding it once.

-- ── The ask ────────────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.wallet_topup_request(
  p_wallet_id    bigint,
  p_amount       numeric,
  p_receipt_url  text,
  p_receipt_path text default null,
  p_reference    text default null,
  p_note         text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_id bigint;
begin
  if not qvm_new_apps.wallet_can_manage(p_wallet_id) then
    return jsonb_build_object('status', false, 'message', 'لا تملك صلاحية على هذه المحفظة', 'data', null);
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('status', false, 'message', 'قيمة الشحن يجب أن تكون أكبر من صفر', 'data', null);
  end if;
  if coalesce(btrim(p_receipt_url), '') = '' then
    return jsonb_build_object('status', false, 'message', 'أرفق إيصال التحويل', 'data', null);
  end if;

  insert into qvm_new_apps.wallet_topup_requests
    (wallet_id, amount, reference, note, receipt_url, receipt_path, requested_by)
  values (p_wallet_id, p_amount, nullif(btrim(p_reference), ''), nullif(btrim(p_note), ''),
          btrim(p_receipt_url), p_receipt_path, auth.uid())
  returning request_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('request_id', v_id));
end
$$;

-- ── The decision ───────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.wallet_topup_decide(
  p_request_id     bigint,
  p_approve        boolean,
  p_reason         text default null,
  p_invoice_url    text default null,
  p_invoice_path   text default null,
  p_invoice_number text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_req    record;
  v_charge jsonb;
  v_entry  bigint;
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'البت في طلبات الشحن من صلاحية قبارتس', 'data', null);
  end if;

  -- Locked before it is read. Two admins opening the same queue and clicking «approve» together
  -- must not both see «pending» — that is the one way this becomes a double credit, and it is
  -- exactly the race wallet_charge locks against one level down.
  select * into v_req from qvm_new_apps.wallet_topup_requests
   where request_id = p_request_id for update;

  if v_req.request_id is null then
    return jsonb_build_object('status', false, 'message', 'طلب الشحن غير موجود', 'data', null);
  end if;
  if v_req.status <> 'pending' then
    -- Says which way it already went. «Already decided» alone sends somebody to go and look.
    return jsonb_build_object('status', false, 'data', jsonb_build_object('status_now', v_req.status),
      'message', case v_req.status when 'approved' then 'تمت الموافقة على هذا الطلب مسبقًا'
                                   else 'تم رفض هذا الطلب مسبقًا' end);
  end if;

  if not p_approve then
    if coalesce(btrim(p_reason), '') = '' then
      -- Refusing without a reason leaves the organisation unable to fix what it was not told.
      return jsonb_build_object('status', false, 'message', 'اذكر سبب الرفض', 'data', null);
    end if;
    update qvm_new_apps.wallet_topup_requests
       set status = 'rejected', reason = btrim(p_reason),
           decided_by = auth.uid(), decided_at = now()
     where request_id = p_request_id;
    return jsonb_build_object('status', true, 'message', 'ok',
      'data', jsonb_build_object('status_now', 'rejected'));
  end if;

  -- The amount credited is the amount that was asked for and evidenced. It is read from the row,
  -- never passed in — an approver who can name their own figure is not approving a request.
  v_charge := qvm_new_apps.wallet_charge(
    p_wallet_id   => v_req.wallet_id,
    p_amount      => v_req.amount,
    p_kind        => 'topup',
    p_description => coalesce(v_req.note, 'شحن رصيد باعتماد طلب #' || v_req.request_id),
    p_reference   => v_req.reference,
    p_source      => 'topup_request',
    p_invoice_url => nullif(btrim(p_invoice_url), ''));

  if not (v_charge ->> 'status')::boolean then
    -- The charge refused, so nothing is recorded as approved. Failing loudly beats a request
    -- marked approved beside a balance that never moved.
    return v_charge;
  end if;

  v_entry := (v_charge -> 'data' ->> 'entry_id')::bigint;

  update qvm_new_apps.wallet_topup_requests
     set status = 'approved', entry_id = v_entry,
         decided_by = auth.uid(), decided_at = now(),
         reason = nullif(btrim(p_reason), ''),
         invoice_url = nullif(btrim(p_invoice_url), ''),
         invoice_path = p_invoice_path,
         invoice_number = nullif(btrim(p_invoice_number), '')
   where request_id = p_request_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'status_now', 'approved', 'entry_id', v_entry,
    'balance', v_charge -> 'data' ->> 'balance'));
end
$$;

-- ── The invoice, afterwards ────────────────────────────────────────────────────────────────────
-- The money should not wait on the paperwork, so approval does not require an invoice. This is
-- how it catches up. Only ever added to an approved request: an invoice for a refused top-up is
-- a document for something that did not happen.
create or replace function qvm_new_apps.wallet_topup_invoice(
  p_request_id     bigint,
  p_invoice_url    text,
  p_invoice_path   text default null,
  p_invoice_number text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_status text;
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'إصدار الفاتورة من صلاحية قبارتس', 'data', null);
  end if;
  if coalesce(btrim(p_invoice_url), '') = '' then
    return jsonb_build_object('status', false, 'message', 'أرفق ملف الفاتورة', 'data', null);
  end if;

  select status into v_status from qvm_new_apps.wallet_topup_requests
   where request_id = p_request_id;
  if v_status is null then
    return jsonb_build_object('status', false, 'message', 'طلب الشحن غير موجود', 'data', null);
  end if;
  if v_status <> 'approved' then
    return jsonb_build_object('status', false, 'message', 'الفاتورة تُصدر للطلبات المعتمدة فقط', 'data', null);
  end if;

  update qvm_new_apps.wallet_topup_requests
     set invoice_url = btrim(p_invoice_url),
         invoice_path = p_invoice_path,
         invoice_number = nullif(btrim(p_invoice_number), '')
   where request_id = p_request_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$$;

grant execute on function qvm_new_apps.wallet_topup_request(bigint, numeric, text, text, text, text)
  to authenticated, service_role;
grant execute on function qvm_new_apps.wallet_topup_decide(bigint, boolean, text, text, text, text)
  to authenticated, service_role;
grant execute on function qvm_new_apps.wallet_topup_invoice(bigint, text, text, text)
  to authenticated, service_role;
