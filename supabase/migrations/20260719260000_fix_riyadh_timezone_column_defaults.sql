-- `now() AT TIME ZONE 'Asia/Riyadh'` was used as the DEFAULT for ~70 created_at/updated_at
-- (and a few date) columns across qvm_new_apps. This is a classic timestamptz trap:
-- `now()` is correct UTC, but `AT TIME ZONE 'Asia/Riyadh'` converts it to a zone-less
-- timestamp holding Riyadh wall-clock time (UTC+3). When that zone-less value is cast back
-- into the timestamptz column, Postgres reinterprets it using the session's timezone (UTC),
-- silently baking in a permanent +3h error into the stored instant.
--
-- This only bit rows whose INSERT omitted the column (falling through to the default) —
-- code paths that explicitly wrote `now()` in their own VALUES list (e.g. set_part_number,
-- add_rfq_item, add_rfq_item_inline) were already correct, which is why the corruption
-- looked inconsistent/random rather than affecting every row uniformly. Confirmed via a bare
-- INSERT relying purely on the column default, bypassing all application code.
--
-- Fixes the default going forward; does not touch already-written historical timestamps.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name
    FROM pg_attrdef d
    JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    JOIN pg_class c ON c.oid = d.adrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE pg_get_expr(d.adbin, d.adrelid) ILIKE '%AT TIME ZONE%Riyadh%'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT now()', r.schema_name, r.table_name, r.column_name);
  END LOOP;
END $$;
