-- A document that was released from a settlement request kept displaying that request's code.
--
-- The list reads a document's settlement through a LATERAL that takes its most recent membership
-- row, whatever became of it. But a membership can end two ways — the transfer covered the
-- document, or the transfer closed without it and the document was released back to «معتمدة».
-- Only the first is still a fact about the document.
--
-- Seen on dev: INV-86 was released when STL-0001 closed on INV-87 alone. Its state correctly went
-- back to «معتمدة» and its money was correctly still owed, and next to that the row said «طلب
-- التسوية: STL-0001» — pointing at a closed request that had not paid it. A supplier reading that
-- would have believed the invoice was handled.
--
-- Two characters of SQL per branch: skip cancelled memberships.
do $do$
declare
  v_def  text := pg_get_functiondef(
    'qvm_new_apps.vendor_documents_list(text,text,integer,text,integer,integer,text)'::regprocedure);
  v_old  text := 'where si.doc_kind = ''invoice'' and si.doc_id = a.attachment_id';
  v_new  text := 'where si.doc_kind = ''invoice'' and si.doc_id = a.attachment_id
           and si.member_status <> ''cancelled''';
  v_old2 text := 'where si.doc_kind = ''return'' and si.doc_id = cn.vendor_creditnote_id';
  v_new2 text := 'where si.doc_kind = ''return'' and si.doc_id = cn.vendor_creditnote_id
           and si.member_status <> ''cancelled''';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the invoice settlement lateral is not where this expects it (% hits)', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / greatest(length(v_old2), 1);
  if v_hits <> 1 then
    raise exception 'the return settlement lateral is not where this expects it (% hits)', v_hits;
  end if;
  execute replace(v_def, v_old2, v_new2);
end
$do$;
