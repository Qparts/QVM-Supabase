-- One invoice is one document, however many purchase orders it covers.
--
-- purchase_invoice_attachments stores a row per (invoice, confirmed order). An invoice covering
-- lines from two orders therefore became two rows, and the invoices screen — which read one row as
-- one document — listed the same invoice twice.
--
-- That is not a display problem. Both rows carry the invoice's FULL total, because the uploader
-- writes the same figure to each, so a 3,000 invoice across two orders counted as 6,000 in the
-- KPI cards, on the statement, and in a settlement request. A supplier would have been paid twice.
-- Seen on dev: «test1234» at 3,000 on PO-13558 and 3,000 on PO-13559.
--
-- Grouping by the file would not work. The smart upload stores one object and points every row at
-- it, but the manual upload re-uploads per order, so the same paper lands at two storage paths
-- with two fingerprints. The identity has to be recorded, not inferred.
--
-- So: invoice_group_id. One uuid per piece of paper, stamped once by whoever files it and carried
-- on every row that paper produced. It defaults to a fresh uuid, which means a row that says
-- nothing is its own invoice — the safe direction, since wrongly splitting one invoice shows two
-- documents a person can see, and wrongly merging two hides a debt.
alter table qvm_new_apps.purchase_invoice_attachments
  add column if not exists invoice_group_id uuid;

comment on column qvm_new_apps.purchase_invoice_attachments.invoice_group_id is
  'The piece of paper. Rows sharing it are one invoice spread over several purchase orders, and '
  'each carries that invoice''s full total — never a share of it.';

-- Backfill. Two rows are the same invoice when they carry the same non-empty number AND belong to
-- the same supplier: an invoice number is unique per supplier by definition, so this cannot merge
-- two real invoices. A row with no number is left alone as its own invoice, because there is
-- nothing to match on and merging on a guess would hide money.
with vend as (
  select a.attachment_id, nullif(a.invoice_number, '') as num, v.vendor_id
    from qvm_new_apps.purchase_invoice_attachments a
    left join lateral (
      select qvi.vendor_id
        from qvm_new_apps.confirmed_items ci
        join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
        join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
       where ci.confirmed_order_id = a.confirmed_order_id
       order by ci.confirmed_item_id limit 1) v on true
), grouped as (
  select num, vendor_id, gen_random_uuid() as grp
    from vend where num is not null and vendor_id is not null
   group by num, vendor_id
)
update qvm_new_apps.purchase_invoice_attachments a
   set invoice_group_id = g.grp
  from vend v join grouped g on g.num = v.num and g.vendor_id = v.vendor_id
 where a.attachment_id = v.attachment_id
   and a.invoice_group_id is null;

update qvm_new_apps.purchase_invoice_attachments
   set invoice_group_id = gen_random_uuid()
 where invoice_group_id is null;

alter table qvm_new_apps.purchase_invoice_attachments
  alter column invoice_group_id set default gen_random_uuid(),
  alter column invoice_group_id set not null;

create index if not exists purchase_invoice_attachments_group_idx
  on qvm_new_apps.purchase_invoice_attachments (invoice_group_id);

-- The uploader stamps it: one uuid generated per file, passed for every order that file covers.
-- Null still means «its own invoice», so every existing caller keeps working unchanged.
drop function if exists public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text);

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
  p_invoice_group_id   uuid default null)
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
    p_issued_on, p_payment_term_days, p_total_amount, v_src,
    COALESCE(p_invoice_group_id, gen_random_uuid())
  ) RETURNING attachment_id INTO v_attachment_id;

  RETURN jsonb_build_object('status','success','message','Attachment added',
    'attachment_id', v_attachment_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;

grant execute on function public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text, uuid)
  to authenticated, service_role;
