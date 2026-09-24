-- A return shows the purchase invoice that was already filed for it.
--
-- The upload screen tells you: «عند رفع فاتورة مرتجع لصنف تم استبداله، لا تنسَ إرفاق فاتورة
-- الشراء السارية أيضًا». Then the returns screen shows no invoice at all, so the person deciding
-- a return cannot see what was bought, for how much, or whether an invoice was ever filed —
-- which is most of what a credit note has to be checked against.
--
-- Added at the `ordered` stage rather than inside the three union branches. They must agree
-- column for column, so touching them means editing the same thing three times and keeping it
-- in step; the final row is `to_jsonb(o)`, so one lateral here reaches every branch at once.
do $do$
declare
  v_def  text := pg_get_functiondef('public.get_return_exchange_dashboard(uuid,text,integer[],integer[],integer[],text,text,integer,integer)'::regprocedure);
  v_old  text := '    ) AS rn
    FROM filtered f
  )';
  v_new  text := '    ) AS rn
    FROM filtered f
    -- Every purchase invoice filed against this row''s order: newest first, so the one that
    -- matters is the one you see. Null total and null date are normal on a smart upload the
    -- model could not read, and the screen says so rather than printing a zero.
    LEFT JOIN LATERAL (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               ''attachment_id'', pia.attachment_id,
               ''invoice_number'', pia.invoice_number,
               ''file_url'', pia.file_url,
               ''issued_on'', pia.issued_on,
               ''total_amount'', pia.total_amount,
               ''uploaded_at'', pia.uploaded_at,
               ''uploaded_source'', pia.uploaded_source)
             ORDER BY pia.uploaded_at DESC), ''[]''::jsonb) AS purchase_invoices
      FROM qvm_new_apps.purchase_invoice_attachments pia
      WHERE pia.confirmed_order_id = f.confirmed_order_id
        AND pia.cancelled_at IS NULL
    ) pinv ON true
  )';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'get_return_exchange_dashboard: expected the ordered tail once, found %', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- and carry it onto the row
  v_old := '    SELECT f.*, row_number() OVER (';
  v_new := '    SELECT f.*, pinv.purchase_invoices, row_number() OVER (';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'get_return_exchange_dashboard: expected the select head once, found %', v_hits;
  end if;

  execute replace(v_def, v_old, v_new);
end
$do$;
