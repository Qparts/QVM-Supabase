-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The unique key predates rules having a tab, so «ch» for one supplier could exist once in
-- the whole table. Now that a rule names a tab, the same supplier's «ch» may legitimately
-- mean different things on the price list and on the stock file, so the tab joins the key.
--
-- The index alone cannot express the real rule, though: a rule with no tab applies to every
-- tab, so it collides with a scoped one without sharing its key. That check lives in the save
-- function, where it can say which rule is in the way. This index stays as the last guard.
drop index if exists qvm_new_apps.upload_code_rules_unique_per_source;

create unique index upload_code_rules_unique_per_source
  on qvm_new_apps.upload_code_rules
  (source_kind, coalesce(source_id, (-1)::bigint), upper(code), "position",
   coalesce(record_kind, '*'));
