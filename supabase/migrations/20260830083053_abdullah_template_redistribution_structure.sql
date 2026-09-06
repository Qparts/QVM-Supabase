-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Meeting with Eng. Abdullah, 2026-08-29: each template goes back to answering one question.
--
-- The agency price list is not the agency's own list — it is **an agency price as the uploading
-- vendor states it**, which is why it now carries a vendor and a branch and the discount pair, and
-- why the stock sheet stops carrying agency prices at all. Past purchases gains the full price
-- triple instead of a single unit cost, because a purchase has a wholesale, a retail and a
-- before-discount figure exactly like everything else.

-- ① The agency list belongs to a vendor and a branch.
alter table qvm_new_apps.agency_price_reference
  add column if not exists vendor_id                    integer,
  add column if not exists vendor_branch_id             bigint,
  add column if not exists part_class                   text,
  add column if not exists agency_price_after_discount  numeric,
  add column if not exists dealer_agency_discount_pct   numeric;

-- The old key said "one agency price per part per source label". With a branch in play the label
-- is no longer the whole identity, and two branches of the same vendor may quote differently.
drop index if exists qvm_new_apps.agency_price_reference_part_source;
create unique index if not exists agency_price_reference_part_vendor_branch
  on qvm_new_apps.agency_price_reference
     (clean_part_number, coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1));

-- ② A purchase has a price triple, not one cost. `cost` stays as the wholesale figure so the
-- price history that already reads it keeps working.
alter table qvm_new_apps.part_purchase_history
  add column if not exists retail_price          numeric,
  add column if not exists before_discount_price numeric;

comment on column qvm_new_apps.part_purchase_history.cost is
  'The wholesale price, before VAT. Named `cost` from before the sheet had a price triple; the
   upload writes wholesale_price here.';

-- ③ inventory_stock keeps its claimed_agency_* columns — rows already written through them stay
-- readable — but the stock sheet no longer offers those columns, so nothing new lands in them.
comment on column qvm_new_apps.inventory_stock.claimed_agency_price is
  'Historical. Agency prices now arrive through the agency_price_list template, which carries the
   vendor and branch that claimed them.';
