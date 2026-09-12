-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The readers stop looking for names nothing advertises any more.
--
-- They were taught to try ID_make, ID_part_class, in_part_number and ID_Vendor_name before
-- falling back to the plain names. That spec is withdrawn and the templates no longer offer
-- those headers, so the aliases are a dead branch pointing at a document nobody follows —
-- and a reader that accepts a header the required check rejects is a trap: the value is
-- found, the row is refused, and the reason names a column the file appears to contain.
--
-- The case-insensitive lookup stays. That was never part of the withdrawn spec: it is what
-- keeps «Part_Number» from silently reading as an empty part number.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_clean_row';

  v_def := replace(v_def, 'upload_raw_get(p_raw, ''in_part_number'', ''part_number'')',
                          'upload_raw_get(p_raw, ''part_number'')');
  v_def := replace(v_def, 'upload_raw_get(p_raw, ''ID_part_class'', ''part_class'')',
                          'upload_raw_get(p_raw, ''part_class'')');
  v_def := replace(v_def, 'upload_raw_get(p_raw, ''ID_make'', ''make'')',
                          'upload_raw_get(p_raw, ''make'')');
  if position('ID_' in v_def) > 0 or position('in_part_number' in v_def) > 0 then
    raise exception 'upload_clean_row still carries a withdrawn alias';
  end if;
  execute v_def;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_batch_write_rows';

  v_def := replace(v_def, 'upload_raw_get(r.raw, ''ID_Vendor_name'', ''supplier_name'')',
                          'upload_raw_get(r.raw, ''supplier_name'')');
  v_def := replace(v_def, 'upload_raw_get(r.raw, ''Vendor_City'', ''city'')',
                          'upload_raw_get(r.raw, ''city'')');
  if position('ID_Vendor_name' in v_def) > 0 or position('Vendor_City' in v_def) > 0 then
    raise exception 'upload_batch_write_rows still carries a withdrawn alias';
  end if;
  execute v_def;
end $$;
