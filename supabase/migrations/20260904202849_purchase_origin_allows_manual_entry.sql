-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- `origin` says where a purchase record came from. Typing one in is now one of the ways, and
-- it is the same axis as the three already listed — not a new one to invent a column for.
alter table qvm_new_apps.part_purchase_history
  drop constraint part_purchase_history_origin_check;

alter table qvm_new_apps.part_purchase_history
  add constraint part_purchase_history_origin_check
  check (origin = any (array['external_excel', 'internal_erp', 'quoted_not_purchased', 'manual_entry']));
