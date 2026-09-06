-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The agency list shows what the supplier sent beside what the system settled on.
--
-- The screen only ever showed the cleaned value, so «why is this part filed as Aftermarket»
-- could not be answered without going back to the file the row came from. The approved
-- values are not copied onto the price row — they live in parts_catalog, curated once per
-- part — so they are joined here, and a correction made there shows up without touching a
-- single price row.
--
-- The English name the supplier wrote was the one raw field with nowhere to land: it is
-- read at staging and was dropped on the way in.

alter table qvm_new_apps.agency_price_reference
  add column if not exists source_name_en text;

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_batch_write_rows';

  if position('source_name_en' in v_def) = 0 then
    v_def := replace(v_def,
      E'       source_name, clean_name, brand, part_class,',
      E'       source_name, source_name_en, clean_name, brand, part_class,');
    v_def := replace(v_def,
      E'           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,',
      E'           r.source_part_number, r.clean_part_number, r.source_name, r.source_name_en, r.clean_name,');
    v_def := replace(v_def,
      E'      source_name = excluded.source_name, clean_name = excluded.clean_name,',
      E'      source_name = excluded.source_name, source_name_en = excluded.source_name_en,\n'
      || E'      clean_name = excluded.clean_name,');
    if position('r.source_name_en' in v_def) = 0 then
      raise exception 'source_name_en was not carried into the publish';
    end if;
    execute v_def;
  end if;
end $$;
