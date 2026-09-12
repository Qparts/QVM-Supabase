-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The rows typed on the records screen before manual entry ran through the cleaning policy
-- kept the supplier's prefix inside their matching key, so the same part sat under two keys
-- depending on how it was entered. The number the person typed is stored separately and is
-- not touched, so this recomputes the key from it rather than inventing anything.
--
-- Only rows with no batch: an imported row's key came from the importer, which was always
-- right, and rewriting those would be reaching into data this did not break.
do $mig$
declare
  r record;
  v_key text;
  v_moved integer := 0;
  v_skipped integer := 0;
begin
  for r in
    select a.id, a.source_part_number, a.clean_part_number, a.vendor_id,
           a.vendor_branch_id, a.client_branch_id
      from qvm_new_apps.agency_price_reference a
     where a.batch_id is null
  loop
    v_key := qvm_new_apps.upload_clean_part_number(
               r.source_part_number, 'agency', 'vendor', r.vendor_id::bigint
             )->>'clean_part_number';

    if v_key is null or v_key = r.clean_part_number then
      continue;
    end if;

    -- The corrected key may already belong to a row that arrived properly cleaned. Merging
    -- two price rows is a decision, not a repair, so that one is left for a person.
    if exists (
      select 1 from qvm_new_apps.agency_price_reference b
       where b.clean_part_number = v_key
         and coalesce(b.vendor_id, -1) = coalesce(r.vendor_id, -1)
         and coalesce(b.vendor_branch_id, -1) = coalesce(r.vendor_branch_id, -1)
         and coalesce(b.client_branch_id, -1) = coalesce(r.client_branch_id, -1)
         and b.id <> r.id)
    then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    update qvm_new_apps.agency_price_reference
       set clean_part_number = v_key
     where id = r.id;
    v_moved := v_moved + 1;
  end loop;

  raise notice 'recleansed % rows, left % for a person', v_moved, v_skipped;
end
$mig$;
