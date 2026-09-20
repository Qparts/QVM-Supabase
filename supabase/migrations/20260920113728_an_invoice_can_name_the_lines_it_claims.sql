-- An invoice can name the lines it claims, not just the orders they sit in.
--
-- A supplier filing an invoice by hand knows exactly which parts are on it. Until now the only
-- thing that could be recorded was the purchase order, so an invoice for two parts out of an
-- order of nine claimed all nine — and the detail panel listed nine lines against a total that
-- covered two.
--
-- purchase_invoice_lines records the claim. Not a replacement for the order link, which still
-- says where the money lands; this says which of that order's lines the paper is about.
--
-- Deliberately a claim and not a fact: the buying side decides what was actually received, and
-- that already lives on purchase_items.receipt_status. A supplier naming lines on their own
-- invoice is telling us what they are billing for, which is exactly what an invoice is.
create table if not exists qvm_new_apps.purchase_invoice_lines (
  attachment_id     bigint not null
    references qvm_new_apps.purchase_invoice_attachments(attachment_id) on delete cascade,
  confirmed_item_id integer not null,
  created_at        timestamptz not null default now(),
  primary key (attachment_id, confirmed_item_id)
);

alter table qvm_new_apps.purchase_invoice_lines enable row level security;

create index if not exists purchase_invoice_lines_item_idx
  on qvm_new_apps.purchase_invoice_lines (confirmed_item_id);

comment on table qvm_new_apps.purchase_invoice_lines is
  'Which confirmed items an invoice bills for. A claim by whoever filed it — what was actually '
  'received is purchase_items.receipt_status, and the two are allowed to disagree.';

-- The uploader can say which lines. Null means «the whole order», which is what every existing
-- caller means and what the smart upload will keep meaning until it learns to read line numbers.
drop function if exists public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text, uuid);

create or replace function public.add_purchase_invoice_attachment(
  p_user_id            uuid,
  p_confirmed_order_id integer,
  p_file_url           text,
  p_invoice_number     text default null,
  p_file_path          text default null,
  p_mime_type          text default null,
  p_file_size          integer default null,
  p_uploaded_source    text default 'internal',
  p_issued_on          date default null,
  p_payment_term_days  integer default null,
  p_total_amount       numeric default null,
  p_amounts_source     text default null,
  p_invoice_group_id   uuid default null,
  p_confirmed_item_ids integer[] default null)
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
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = COALESCE(auth.uid(), p_user_id);
  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    IF v_user_type = 205 AND EXISTS (
      SELECT 1
        FROM qvm_new_apps.confirmed_items ci
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
        JOIN qvm_new_apps.user_data ud ON ud.user_vendor = qvi.vendor_id
       WHERE ci.confirmed_order_id = p_confirmed_order_id
         AND ud.user_id = COALESCE(auth.uid(), p_user_id)
    ) THEN
      p_uploaded_source := 'vendor';
    ELSE
      RETURN jsonb_build_object('status','error','message','Access denied');
    END IF;
  END IF;

  IF p_issued_on IS NOT NULL AND p_issued_on > current_date THEN
    RETURN jsonb_build_object('status','error','message','تاريخ الفاتورة لا يمكن أن يكون في المستقبل');
  END IF;

  v_src := CASE
    WHEN p_issued_on IS NULL AND p_total_amount IS NULL AND p_payment_term_days IS NULL THEN NULL
    WHEN p_amounts_source IN ('ai','manual') THEN p_amounts_source
    ELSE 'manual'
  END;

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
    uploaded_by, uploaded_at, uploaded_source, issued_on, payment_term_days, total_amount,
    amounts_source, invoice_group_id
  ) VALUES (
    p_confirmed_order_id, v_purchase_order_id, p_file_url, NULLIF(p_invoice_number,''), p_file_path,
    p_mime_type, p_file_size, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'),
    p_issued_on, COALESCE(p_payment_term_days, 30), p_total_amount, v_src,
    COALESCE(p_invoice_group_id, gen_random_uuid())
  ) RETURNING attachment_id INTO v_attachment_id;

  -- Only lines that belong to the order being filed against. A caller naming someone else's line
  -- gets it dropped rather than the whole upload refused: the rest of the invoice is still true.
  IF p_confirmed_item_ids IS NOT NULL AND array_length(p_confirmed_item_ids, 1) > 0 THEN
    INSERT INTO qvm_new_apps.purchase_invoice_lines(attachment_id, confirmed_item_id)
    SELECT v_attachment_id, ci.confirmed_item_id
      FROM qvm_new_apps.confirmed_items ci
     WHERE ci.confirmed_item_id = ANY (p_confirmed_item_ids)
       AND ci.confirmed_order_id = p_confirmed_order_id
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object('status','success','message','Attachment added',
    'attachment_id', v_attachment_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;

grant execute on function public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text, uuid, integer[])
  to authenticated, service_role;
