-- An invoice can be dated by hand, and says which way it was read.
--
-- Everything the invoices screen decides about money hangs off three facts: the date on the paper,
-- the payment term, and the amount. Nothing in the application was writing any of them. The smart
-- upload reads all three off the image and then threw them away; the manual upload never had
-- anywhere to put them. Every invoice filed through the app arrived with a null date and a null
-- total, which is why the list shows «0.00» and why a due date was being computed from the day of
-- upload rather than the day on the invoice — an invoice already two weeks old on arrival read as
-- fresh and would go overdue a fortnight late, quietly.
--
-- Three optional arguments fix the writing. Optional, because the smart upload fills them itself
-- and a required field would put a date entry in front of a path that already knows the answer.
--
-- And a fourth thing recorded beside them: HOW they were obtained. A figure a model read off a
-- photograph and a figure a person typed are not the same kind of fact, and the screen that asks
-- someone to approve a payment should say which one it is showing. 'ai' and 'manual'; null on the
-- rows that predate this, because «we do not know» is the honest answer for those and inventing a
-- value for them would put a confidence on records that never earned one.
--
-- `amounts_source` follows the naming already used for the customer invoices, which distinguish a
-- Zoho-synced total from a computed one for the same reason.
alter table qvm_new_apps.purchase_invoice_attachments
  add column if not exists amounts_source text
    check (amounts_source in ('ai', 'manual'));

comment on column qvm_new_apps.purchase_invoice_attachments.amounts_source is
  'How issued_on / payment_term_days / total_amount were obtained: ''ai'' read from the file, '
  '''manual'' typed by a person. Null on rows filed before this was recorded.';

-- Dropped and recreated rather than replaced: the argument list changes. A CREATE OR REPLACE with
-- four more parameters would leave the old function standing beside the new one, and a PostgREST
-- call naming its arguments would then be ambiguous between them rather than simply reaching the
-- wrong one.
drop function if exists public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text);

create or replace function public.add_purchase_invoice_attachment(
  p_user_id            uuid,
  p_confirmed_order_id integer,
  p_file_url           text,
  p_invoice_number     text default null,
  p_file_path          text default null,
  p_mime_type          text default null,
  p_file_size          integer default null,
  p_uploaded_source    text default 'internal',
  -- The three the money screen reads. Null means «not stated here», never «zero».
  p_issued_on          date default null,
  p_payment_term_days  integer default null,
  p_total_amount       numeric default null,
  p_amounts_source     text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_attachment_id bigint;
  v_src text;
BEGIN
  -- Who is asking is the JWT's answer, not the request body's. p_user_id is kept for
  -- attribution and no longer decides anything; with no JWT (service role) it is all there is.
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = COALESCE(auth.uid(), p_user_id);
  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    -- A vendor, and only on an order they hold a line of.
    IF v_user_type = 205 AND EXISTS (
      SELECT 1
        FROM qvm_new_apps.confirmed_items ci
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
        JOIN qvm_new_apps.user_data ud ON ud.user_vendor = qvi.vendor_id
       WHERE ci.confirmed_order_id = p_confirmed_order_id
         AND ud.user_id = COALESCE(auth.uid(), p_user_id)
    ) THEN
      -- An uploader does not get to say what kind of uploader they were.
      p_uploaded_source := 'vendor';
    ELSE
      RETURN jsonb_build_object('status','error','message','Access denied');
    END IF;
  END IF;

  -- A date in the future is a typo, not a fact. Refused rather than stored, because an invoice
  -- dated next month never falls due and would sit in «معتمدة» forever.
  IF p_issued_on IS NOT NULL AND p_issued_on > current_date THEN
    RETURN jsonb_build_object('status','error','message','تاريخ الفاتورة لا يمكن أن يكون في المستقبل');
  END IF;

  -- Claimed only when there is something to claim it about: 'manual' on a row with no figures
  -- would be a label on nothing.
  v_src := CASE
    WHEN p_issued_on IS NULL AND p_total_amount IS NULL AND p_payment_term_days IS NULL THEN NULL
    WHEN p_amounts_source IN ('ai','manual') THEN p_amounts_source
    ELSE 'manual'
  END;

  -- Ensure a purchase_order exists (stub if needed)
  SELECT purchase_order_id INTO v_purchase_order_id
  FROM purchase_orders
  WHERE confirmed_order_id = p_confirmed_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_purchase_order_id IS NULL THEN
    INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  END IF;

  INSERT INTO purchase_invoice_attachments(
    confirmed_order_id, purchase_order_id, file_url, invoice_number, file_path, mime_type, file_size,
    uploaded_by, uploaded_at, uploaded_source, issued_on, payment_term_days, total_amount, amounts_source
  ) VALUES (
    p_confirmed_order_id, v_purchase_order_id, p_file_url, NULLIF(p_invoice_number,''), p_file_path,
    p_mime_type, p_file_size, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'),
    p_issued_on, p_payment_term_days, p_total_amount, v_src
  ) RETURNING attachment_id INTO v_attachment_id;

  RETURN jsonb_build_object('status','success','message','Attachment added','attachment_id', v_attachment_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;

-- The same figures, correctable after the fact.
--
-- Filing the invoice and knowing what it says are not always the same moment: a scan is read
-- wrong, a supplier sends the real numbers afterwards, someone notices the due date is a fortnight
-- out. Without this the only remedy would be re-uploading the file, leaving two attachments on one
-- order and no way to tell which is the real one.
--
-- Correcting always stamps 'manual', whatever the row said before. A person has now looked at the
-- number, and that is a stronger claim than the one the model made — recording it as anything else
-- would lose the only fact this column exists to carry.
--
-- Not editable once approved. Approval is a statement that these figures were checked, and moving
-- the amount underneath it would make that statement about numbers nobody saw. Approval happens
-- after this, not before, so the ordinary case is never blocked.
create or replace function qvm_new_apps.purchase_invoice_set_terms(
  p_attachment_id     bigint,
  p_issued_on         date default null,
  p_payment_term_days integer default null,
  p_total_amount      numeric default null,
  p_invoice_number    text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_approved timestamptz;
  v_exists   boolean;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تعديل بيانات الفاتورة من صلاحية المشتريات');
  end if;

  select true, approved_at into v_exists, v_approved
    from qvm_new_apps.purchase_invoice_attachments
   where attachment_id = p_attachment_id;

  if not coalesce(v_exists, false) then
    return jsonb_build_object('status', false, 'message', 'المستند غير موجود', 'data', null);
  end if;
  if v_approved is not null then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'لا يمكن تعديل بيانات فاتورة معتمدة');
  end if;
  if p_issued_on is not null and p_issued_on > current_date then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'تاريخ الفاتورة لا يمكن أن يكون في المستقبل');
  end if;

  -- COALESCE, not assignment: a field left blank means «leave it», not «clear it».
  update qvm_new_apps.purchase_invoice_attachments
     set issued_on         = coalesce(p_issued_on, issued_on),
         payment_term_days = coalesce(p_payment_term_days, payment_term_days),
         total_amount      = coalesce(p_total_amount, total_amount),
         invoice_number    = coalesce(nullif(btrim(coalesce(p_invoice_number, '')), ''), invoice_number),
         amounts_source    = 'manual'
   where attachment_id = p_attachment_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('attachment_id', p_attachment_id));
end
$$;

-- The detail panel needs to say which way it was read, right beside who approved it.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_document_detail(text,bigint)'::regprocedure);
  v_old text := '             ''match_pct'', a.match_pct,';
  v_new text := '             ''match_pct'', a.match_pct,
             -- A number a model read off a photograph and a number a person typed are not the
             -- same kind of fact; whoever approves a payment should see which one this is.
             ''amounts_source'', a.amounts_source,';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_document_detail: expected the invoice file block once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

revoke all on function qvm_new_apps.purchase_invoice_set_terms(bigint, date, integer, numeric, text) from public;
grant execute on function qvm_new_apps.purchase_invoice_set_terms(bigint, date, integer, numeric, text)
  to authenticated, service_role;
-- The dropped function's grants go with it. These are the ones it had: authenticated and
-- service_role, and deliberately not anon — filing an invoice against a purchase order is not
-- something an unauthenticated caller does.
grant execute on function public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text)
  to authenticated, service_role;
