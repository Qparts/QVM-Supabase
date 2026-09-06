-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Decision on 2026-08-30: the upload screen offers three file types, not seven. Agency price list,
-- stock on hand and past purchases are the three that feed pricing; the rest were scope that had
-- not been agreed.
--
-- Deactivated rather than deleted. `is_active` is exactly the flag the page filters on, the work
-- already built stays intact behind it, and turning one back on is a single update — whereas
-- deleting the row would take its columns, its guidance text and the shape of anything already
-- uploaded against it with it.
update qvm_new_apps.upload_templates
   set is_active = false
 where template_key in ('aliases', 'offers', 'group_import_request', 'stock_auction');

select template_key, is_active, sort_order from qvm_new_apps.upload_templates order by sort_order;
