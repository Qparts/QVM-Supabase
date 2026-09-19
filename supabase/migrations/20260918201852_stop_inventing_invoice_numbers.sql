-- Stop inventing invoice numbers.
--
-- The list synthesised `'INV-' || attachment_id` whenever the supplier's own number was missing, so
-- a row filed without one displayed «INV-91». That reads exactly like an invoice number and is not
-- one: it is our row id wearing a prefix. Somebody would quote it back to a supplier, who would
-- have no idea what it referred to — and worse, two different databases would hand out the same
-- «INV-91» for two unrelated invoices.
--
-- `code` now carries the supplier's number or null, and `code_missing` says which. The screen shows
-- «بلا رقم» rather than a plausible-looking fabrication, and the number can be typed in afterwards
-- — purchase_invoice_set_terms already takes one.
--
-- The internal id is still there as `doc_key` ('invoice:91'), which is what the screen uses to
-- point at a row. That is a handle, not an identifier for the paper, and it never appears in a
-- column headed «رقم المستند».
--
-- The same for credit notes, and the same on the statement, where a fabricated reference on a line
-- of a balance is exactly the wrong place for one.
do $do$
declare
  v_def  text;
  v_hits integer;
  v_old  text;
  v_new  text;
begin
  -- ── the documents list ───────────────────────────────────────────────────────────────────────
  v_def := pg_get_functiondef(
    'qvm_new_apps.vendor_documents_list(text,text,integer,text,integer,integer,text,text,text)'::regprocedure);

  v_old := 'coalesce(nullif(a.invoice_number,''''), ''INV-'' || a.attachment_id) as code,';
  v_new := 'nullif(a.invoice_number,'''') as code,
           nullif(a.invoice_number,'''') is null as code_missing,';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the invoice code expression is not where this expects it (% hits)', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := 'coalesce(nullif(cn.vendor_creditnote_number,''''), ''RET-'' || cn.vendor_creditnote_id),';
  v_new := 'nullif(cn.vendor_creditnote_number,''''),
           nullif(cn.vendor_creditnote_number,'''') is null,';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the credit-note code expression is not where this expects it (% hits)', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- The search still has to match on something a person can type, and «بلا رقم» is not it. The
  -- purchase order and the supplier name carry that weight for a numberless document.
  v_old := 'and (v_q is null or d.code ilike ''%''||v_q||''%''';
  v_new := 'and (v_q is null or coalesce(d.code,'''') ilike ''%''||v_q||''%''';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the search clause is not where this expects it (% hits)', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

  -- ── the statement ────────────────────────────────────────────────────────────────────────────
  v_def := pg_get_functiondef('qvm_new_apps.vendor_statement(integer,date,date)'::regprocedure);

  v_old := 'coalesce(nullif(a.invoice_number,''''), ''INV-'' || a.attachment_id) as ref,';
  v_new := 'nullif(a.invoice_number,'''') as ref,';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the statement invoice ref is not where this expects it (% hits)', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := 'coalesce(nullif(cn.vendor_creditnote_number,''''), ''RET-'' || cn.vendor_creditnote_id),';
  v_new := 'nullif(cn.vendor_creditnote_number,''''),';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the statement credit-note ref is not where this expects it (% hits)', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
