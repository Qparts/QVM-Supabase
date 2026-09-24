-- `signed_total` is what is still owed, signed — not the gross.
--
-- The previous version read it as the net value of the document and got zero for every
-- settlement, because every document on this database is settled and `signed_total` is zero the
-- moment nothing is outstanding. total=3795, settled=3795, signed_total=0.00 across the board.
--
-- So it is the remaining amount carrying its own sign, which is a better field than the one I
-- assumed existed: invoices positive, credit notes negative, already net of what has been paid.
-- The net value of the request is the gross with the same sign rule applied, and `doc_kind` on
-- the member is what says which way.
--
-- Checked against the members rather than named from memory. Twice now on this one function the
-- plausible-looking field has been the wrong field, and both times it produced a confident zero
-- instead of an error.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.vendor_settlement_detail(bigint)'::regprocedure);
  v_old  text := '        -- Net: invoices add, credit notes subtract. This is «صافي مبلغ الطلب».
        ''net'',       coalesce(sum((m->''document''->>''signed_total'')::numeric), 0),
        ''settled'',   coalesce(sum((m->''document''->>''settled'')::numeric), 0),
        ''remaining'', coalesce(sum(
                         (m->''document''->>''signed_total'')::numeric
                         - coalesce((m->''document''->>''settled'')::numeric, 0)), 0))';
  v_new  text := '        -- Net: invoices add, credit notes subtract. This is «صافي مبلغ الطلب»,
        -- and `doc_kind` is what carries the sign.
        ''net'',       coalesce(sum(case when m->>''doc_kind'' = ''creditnote''
                                         then -(m->''document''->>''total'')::numeric
                                         else  (m->''document''->>''total'')::numeric end), 0),
        ''settled'',   coalesce(sum((m->''document''->>''settled'')::numeric), 0),
        -- Already signed and already net of what has been paid, straight off the document.
        ''remaining'', coalesce(sum((m->''document''->>''signed_total'')::numeric), 0))';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_detail: expected the net block once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
