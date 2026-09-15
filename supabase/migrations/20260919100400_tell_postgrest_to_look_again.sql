-- Tell PostgREST to read the schema again.
--
-- After the previous push, upsert_vendor_costs and the approval functions answered (with a
-- permission error, which is a function that exists refusing a caller) while last_purchase_prices
-- and the workshop functions came back PGRST202 — not found. Both pairs went out in the same
-- commit, and both are valid against the live schema, so the database has them and PostgREST does
-- not: its cache was built partway through the deploy and nothing has invalidated it since.
--
-- This is the documented way to say so. It is cheap, it is idempotent, and it costs nothing if the
-- cache was already current.
NOTIFY pgrst, 'reload schema';

-- Deliberately nothing else in this file. A COMMENT ON one of the missing functions would have
-- been a neater diagnostic, but if those functions really did fail to create, the COMMENT fails too
-- and blocks the deploy a second time — turning the probe into another outage. A bare NOTIFY can
-- only tell the truth: if they reappear, the cache was stale; if they do not, they were never made.
