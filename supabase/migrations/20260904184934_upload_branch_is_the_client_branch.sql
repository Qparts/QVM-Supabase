-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The branch an upload is scoped to is one of OUR branches, not the supplier's.
--
-- The screen asks «which branches does this file cover», and the answer people give is the
-- workshop branch they are standing in — the same list the header switcher shows, because
-- that is the context they are working in. The module was built the other way round: the id
-- went into vendor_branch_id, so the answer was read as «which of the supplier's depots».
--
-- Those are different things and they cannot share a column. vendor_branch_id is part of
-- each row's natural key, so putting a client branch there would key a supplier's price by
-- one of our branches and quietly duplicate the row once per branch ticked.
--
-- So the client branch gets its own column, and joins the natural key beside the vendor one.
-- Both stay meaningful: a supplier depot can still be recorded where it is known, and the
-- branch a file was uploaded for is now recorded as what it is.

alter table qvm_new_apps.agency_price_reference
  add column if not exists client_branch_id integer;
alter table qvm_new_apps.inventory_stock
  add column if not exists client_branch_id integer;

-- The key gains the new column so two branches' files stay two rows instead of one
-- overwriting the other.
drop index if exists qvm_new_apps.agency_price_reference_part_vendor_branch;
create unique index agency_price_reference_part_vendor_branch
  on qvm_new_apps.agency_price_reference
     (clean_part_number,
      coalesce(vendor_id, -1),
      coalesce(vendor_branch_id, -1::bigint),
      coalesce(client_branch_id, -1));

drop index if exists qvm_new_apps.inventory_stock_natural_key;
create unique index inventory_stock_natural_key
  on qvm_new_apps.inventory_stock
     (coalesce(vendor_id, -1),
      coalesce(vendor_branch_id, -1::bigint),
      coalesce(client_branch_id, -1),
      clean_part_number);
