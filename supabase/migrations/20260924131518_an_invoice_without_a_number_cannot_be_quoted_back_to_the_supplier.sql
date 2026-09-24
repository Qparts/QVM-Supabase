-- An invoice without a number cannot be quoted back to the supplier.
--
-- `add_purchase_invoice_attachment` stored `NULLIF(p_invoice_number, '')` — an empty number was
-- accepted and became null. Every downstream screen then shows «بلا رقم», which is exactly what
-- the settlement panel is full of today, and a settlement of six «بلا رقم» documents is one
-- nobody can reconcile against the supplier's own statement.
--
-- Required now, on the same principle as the credit note: a rule that lives only in a form is a
-- rule the next screen will not have.
--
-- WORTH KNOWING: this also binds the smart upload. If the model cannot read a number off the
-- page, that upload will now be refused rather than filed as «بلا رقم». That is the intended
-- trade — an unfileable invoice is a problem at the moment of upload, when somebody is holding
-- the paper, rather than a month later when the amounts disagree.
do $do$
declare
  v_def  text := pg_get_functiondef('public.add_purchase_invoice_attachment(uuid,integer,text,text,text,text,integer,text,date,integer,numeric,text,uuid,integer[],bigint)'::regprocedure);
  v_old  text := 'BEGIN';
  v_new  text := 'BEGIN
  -- A document nobody can name is a document nobody can reconcile.
  IF NULLIF(BTRIM(COALESCE(p_invoice_number, '''')), '''') IS NULL THEN
    RETURN jsonb_build_object(''status'', false, ''data'', null,
      ''message'', ''رقم فاتورة الشراء مطلوب'');
  END IF;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'add_purchase_invoice_attachment: expected one BEGIN, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
