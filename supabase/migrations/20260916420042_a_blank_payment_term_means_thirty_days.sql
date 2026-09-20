-- A blank payment term means thirty days, not null.
--
-- purchase_invoice_attachments.payment_term_days is NOT NULL DEFAULT 30. When the term became an
-- argument two migrations ago the insert started naming the column explicitly, and an explicitly
-- inserted NULL does not fall back to a column default — it violates the constraint. So any upload
-- that did not state a term failed outright:
--
--   null value in column "payment_term_days" of relation "purchase_invoice_attachments"
--   violates not-null constraint
--
-- That is the smart upload's ordinary path: it reads a date and a total off the invoice and has
-- nothing to say about the term, because almost no invoice prints one. The feature meant to make
-- the figures fillable had instead made filing an invoice impossible unless you filled them.
--
-- Thirty days for everyone, for now. It is the column's own default and the figure every due date
-- in this system has been computed from since the state machine was written — so nothing changes
-- for existing invoices, and the ones that were failing simply land where they always would have.
--
-- It is a placeholder, and worth naming as one: a term belongs to the agreement with a supplier,
-- not to every invoice alike. When supplier terms are recorded, this coalesce is the single place
-- that has to start reading them, and an invoice that states its own term already overrides it.
do $do$
declare
  v_def text := pg_get_functiondef(
    'public.add_purchase_invoice_attachment(uuid,integer,text,text,text,text,integer,text,date,integer,numeric,text,uuid)'::regprocedure);
  v_old text := '    p_issued_on, p_payment_term_days, p_total_amount, v_src,';
  v_new text := '    -- Explicit NULL would override the column default and fail the not-null constraint,
    -- so the default is applied here instead. Thirty days until supplier terms are recorded.
    p_issued_on, COALESCE(p_payment_term_days, 30), p_total_amount, v_src,';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'add_purchase_invoice_attachment: expected the insert values once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- The correction path has the same hole from the other direction: passing an explicit null to
-- clear a term would fail the constraint rather than doing nothing. It already coalesces onto the
-- existing value, which is never null — this only states it, so the next reader does not "tidy"
-- the coalesce away.
comment on function qvm_new_apps.purchase_invoice_set_terms(bigint, date, integer, numeric, text) is
  'Corrects an unapproved invoice''s figures. A null argument means «leave this one alone» — for '
  'payment_term_days that is also what keeps the NOT NULL constraint satisfied.';
