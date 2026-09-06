-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The device panel stopped working: «nextval: reached maximum value of sequence
-- "wa_device_state_id_seq" (32767)».
--
-- The table holds one row per number — three of them — and its id was a smallserial,
-- so the ceiling was 32767. It got there because of how the row is written: an
-- INSERT … ON CONFLICT DO UPDATE evaluates the column defaults *before* it finds the
-- conflict, so every heartbeat called nextval and then threw the value away. Three
-- bridges reporting every thirty seconds is about 8,600 a day, which burns 32,767 in
-- under four days. Three rows had consumed 32,764 ids.
--
-- Both halves are fixed, because either alone still leaves something wrong: widening
-- the type alone keeps the pointless churn, and stopping the churn alone leaves the
-- sequence already sitting on its exhausted maximum.

alter sequence qvm_new_apps.wa_device_state_id_seq
  as bigint maxvalue 9223372036854775807;

alter table qvm_new_apps.wa_device_state
  alter column id type bigint;
