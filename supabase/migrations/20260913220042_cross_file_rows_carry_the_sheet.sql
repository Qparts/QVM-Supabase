-- The cross-file rows reader was returning five fields out of a sheet that had seven columns.
--
-- Part number, name, supplier, file, state. Everything else the supplier actually sent — «Bill
-- Date», «Quantity», «Item Total قبل الضريبة», «Vendor city» — was read during cleanup, used, and
-- then not shown. Looking at 59 analysed rows told you almost nothing about them, because the
-- columns that make a purchase a purchase were all missing.
--
-- upload_rows carries raw_source: the row exactly as the sheet had it, under the sheet's own
-- header names rather than the canonical keys they were mapped to. That is the right thing to
-- hand back — «Item Total قبل الضريبة» is what the person who made the file will recognise, and
-- 'wholesale_price' is what this system decided it meant. Both are available; only one of them is
-- evidence.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.upload_rows_across_files(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $old$               'state', r.state, 'reason', r.reason, 'raw', r.raw)$old$,
    $new$               'state', r.state, 'reason', r.reason, 'raw', r.raw,
               -- The sheet's own headers and values. Null on rows staged before raw_source
               -- existed, which the screen has to treat as «no sheet columns», not as an error.
               'raw_source', r.raw_source)$new$);
  if v_new = v_def then
    raise exception 'upload_rows_across_files: the row object was not found';
  end if;
  v_def := v_new;

  v_new := replace(v_def,
    $old$                 u.clean_name, u.source_name, u.state, u.reason, u.raw,$old$,
    $new$                 u.clean_name, u.source_name, u.state, u.reason, u.raw, u.raw_source,$new$);
  if v_new = v_def then
    raise exception 'upload_rows_across_files: the column list was not found';
  end if;
  execute v_new;
end
$patch$;
