-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The approved half of every row, joined from the catalog that curates it.
--
-- The screen only ever showed the cleaned value, so «why is this filed as Aftermarket»
-- could not be answered without going back to the file. The approved values are not copied
-- onto the price row — they live in parts_catalog, curated once per part — so a correction
-- made there shows up here without touching a single price row.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'uploaded_records_get';
  if v_def is null then raise exception 'uploaded_records_get not found'; end if;
  if position('official_make' in v_def) > 0 then return; end if;

  v_def := replace(v_def,
    E'                 ''effective_from'', a.effective_from, ''expires_on'', a.expires_on,',
    E'                 ''raw_name_en'', a.source_name_en,\n'
    || E'                 ''official_part_number'', a.clean_part_number,\n'
    || E'                 ''official_name_ar'', pc.clean_name_ar,\n'
    || E'                 ''official_name_en'', pc.clean_name_en,\n'
    || E'                 ''official_make'', pc.clean_make,\n'
    || E'                 ''official_part_class'', pc.clean_part_class,\n'
    || E'                 ''official_origin'', pc.clean_country_manufacture,\n'
    || E'                 ''effective_from'', a.effective_from, ''expires_on'', a.expires_on,');

  v_def := replace(v_def,
    E'          from qvm_new_apps.agency_price_reference a\n'
    || E'          left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id',
    E'          from qvm_new_apps.agency_price_reference a\n'
    || E'          left join qvm_new_apps.parts_catalog pc on pc.clean_part_number = a.clean_part_number\n'
    || E'          left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id');

  if position('official_origin' in v_def) = 0 then
    raise exception 'the approved fields were not added';
  end if;
  if position('parts_catalog pc' in v_def) = 0 then
    raise exception 'the catalog join was not added';
  end if;
  execute v_def;
end $$;
