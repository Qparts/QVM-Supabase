-- The branch-scoped get_vendor_emails(p_vendor_ids, p_vendor_branch_id) was added via
-- CREATE OR REPLACE, which does not replace a function with a different argument list — it just
-- adds an overload. Postgres allows both signatures to coexist, but PostgREST's RPC resolver
-- can't disambiguate between them (the branch id has a DEFAULT, so both match a 1-arg call),
-- causing "Could not choose the best candidate function" (PGRST203). Drop the stale 1-arg one.
DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_emails(p_vendor_ids integer[]);
