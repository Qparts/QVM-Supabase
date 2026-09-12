-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The two templates that ask for a branch now write it as a client branch.
--
-- Only these two are touched. Offers and auctions also carry a branch, but they are
-- inactive and their branch has always meant the supplier's — changing them here would be
-- changing something nobody is using on a guess about what it should mean.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_batch_write_rows';
  if v_def is null then raise exception 'upload_batch_write_rows not found'; end if;
  if position('client_branch_id' in v_def) > 0 then return; end if;

  -- agency_price_list
  v_def := replace(v_def,
    '    insert into qvm_new_apps.agency_price_reference' || E'\n'
    || '      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,',
    '    insert into qvm_new_apps.agency_price_reference' || E'\n'
    || '      (vendor_id, client_branch_id, source_part_number, clean_part_number,');
  v_def := replace(v_def,
    'on conflict (clean_part_number, coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1))',
    'on conflict (clean_part_number, coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1::bigint), coalesce(client_branch_id, -1))');

  -- stock_on_hand
  v_def := replace(v_def,
    '    insert into qvm_new_apps.inventory_stock' || E'\n'
    || '      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,',
    '    insert into qvm_new_apps.inventory_stock' || E'\n'
    || '      (vendor_id, client_branch_id, source_part_number, clean_part_number,');
  v_def := replace(v_def,
    'on conflict (coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1), clean_part_number)',
    'on conflict (coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1::bigint), coalesce(client_branch_id, -1), clean_part_number)');

  if (select count(*) from regexp_matches(v_def, 'client_branch_id', 'g')) < 4 then
    raise exception 'the client-branch rewrite did not take in both templates';
  end if;
  execute v_def;
end $$;
