-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The readers follow the headers: new name first, previous name second, case-insensitive.
do $$
declare v_def text;
begin
  -- ── upload_clean_row: part number, brand, class ────────────────────────────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_clean_row';
  if v_def is null then raise exception 'upload_clean_row not found'; end if;

  if position('upload_raw_get' in v_def) = 0 then
    v_def := replace(v_def,
      'nullif(btrim(coalesce(p_raw->>''part_number'', '''')), '''')',
      'qvm_new_apps.upload_raw_get(p_raw, ''in_part_number'', ''part_number'')');
    v_def := replace(v_def,
      'nullif(btrim(coalesce(p_raw->>''part_class'', '''')), '''')',
      'qvm_new_apps.upload_raw_get(p_raw, ''ID_part_class'', ''part_class'')');
    v_def := replace(v_def,
      'nullif(btrim(coalesce(p_raw->>''make'', '''')), '''')',
      'qvm_new_apps.upload_raw_get(p_raw, ''ID_make'', ''make'')');

    if position('''in_part_number''' in v_def) = 0
       or position('''ID_part_class''' in v_def) = 0
       or position('''ID_make''' in v_def) = 0 then
      raise exception 'upload_clean_row: a rename did not apply';
    end if;
    execute v_def;
  end if;

  -- ── upload_batch_write_rows: the vendor, and the city it never stored ──────
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_batch_write_rows';
  if v_def is null then raise exception 'upload_batch_write_rows not found'; end if;

  if position('ID_Vendor_name' in v_def) = 0 then
    -- The insert gains city, so the column list and the values list both move.
    v_def := replace(v_def,
      '       supplier_name, qty, brand, brand_class, origin, batch_id)',
      '       supplier_name, city, qty, brand, brand_class, origin, batch_id)');
    v_def := replace(v_def,
      '           r.raw->>''supplier_name'',' || E'\n'
      || '           nullif(r.raw->>''qty'','''')::integer,',
      '           qvm_new_apps.upload_raw_get(r.raw, ''ID_Vendor_name'', ''supplier_name''),' || E'\n'
      || '           qvm_new_apps.upload_raw_get(r.raw, ''Vendor_City'', ''city''),' || E'\n'
      || '           nullif(r.raw->>''qty'','''')::integer,');

    -- The same purchase from the same supplier in two cities is two purchases, so the
    -- city belongs in what decides «already have this row».
    v_def := replace(v_def,
      '            and coalesce(h.supplier_name,'''') = coalesce(r.raw->>''supplier_name'','''')',
      '            and coalesce(h.supplier_name,'''') = coalesce(qvm_new_apps.upload_raw_get(r.raw, ''ID_Vendor_name'', ''supplier_name''),'''')' || E'\n'
      || '            and coalesce(h.city,'''') = coalesce(qvm_new_apps.upload_raw_get(r.raw, ''Vendor_City'', ''city''),'''')');

    if position('supplier_name, city, qty' in v_def) = 0
       or position('''Vendor_City''' in v_def) = 0
       or position('h.city' in v_def) = 0 then
      raise exception 'upload_batch_write_rows: a rename did not apply';
    end if;
    execute v_def;
  end if;
end $$;
