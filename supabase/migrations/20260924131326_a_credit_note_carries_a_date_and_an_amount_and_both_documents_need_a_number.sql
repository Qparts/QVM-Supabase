-- A credit note carries a date and an amount, and both documents need a number.
--
-- `vendor_creditnotes` has had `issued_on`, `total_amount` and `vendor_creditnote_number` since
-- it was created. Nothing ever filled them: the upload screen offers a file and nothing else,
-- and `upsert_vendor_creditnote` takes no date and no amount. So a credit note is a PDF with an
-- upload timestamp — it cannot be aged, cannot be netted against what is owed, and cannot be
-- matched to the supplier's own paperwork.
--
-- Two of those columns exist and two arguments were missing. That is the whole of it.
--
-- The number becomes required on both sides, which is the change with teeth: a document with no
-- number is one nobody can quote back to the supplier when the amounts disagree. Enforced here
-- rather than in the form, because a rule that only lives in a form is a rule the next screen
-- will not have.
drop function if exists qvm_new_apps.upsert_vendor_creditnote(uuid, integer, text, text, text);

create or replace function qvm_new_apps.upsert_vendor_creditnote(
  p_user_id                uuid,
  p_confirmed_order_id     integer,
  p_vendor_creditnote_url  text,
  p_vendor_creditnote_number text,
  p_uploaded_source        text default 'internal',
  p_issued_on              date default null,
  p_total_amount           numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_po  bigint;
  v_id  bigint;
  v_num text := nullif(btrim(p_vendor_creditnote_number), '');
begin
  if v_num is null then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'رقم إشعار الدائن مطلوب');
  end if;
  if p_total_amount is not null and p_total_amount < 0 then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'مبلغ الإشعار لا يمكن أن يكون سالبًا');
  end if;
  -- A credit note dated in the future is a typo every time.
  if p_issued_on is not null and p_issued_on > current_date then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تاريخ الإشعار لا يمكن أن يكون في المستقبل');
  end if;

  select co.purchase_order_id into v_po
    from qvm_new_apps.confirmed_orders co
   where co.confirmed_order_id = p_confirmed_order_id;

  insert into qvm_new_apps.vendor_creditnotes
    (purchase_order_id, vendor_creditnote_number, vendor_creditnote_url,
     uploaded_by, uploaded_at, uploaded_source, issued_on, total_amount)
  values (v_po, v_num, p_vendor_creditnote_url,
          p_user_id, now(), coalesce(p_uploaded_source, 'internal'),
          p_issued_on, p_total_amount)
  returning vendor_creditnote_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('vendor_creditnote_id', v_id));
end
$$;

grant execute on function qvm_new_apps.upsert_vendor_creditnote(
  uuid, integer, text, text, text, date, numeric) to authenticated, service_role;
