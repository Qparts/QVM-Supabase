-- create_internal_user / update_internal_user / delete_internal_user insert/delete this table
-- directly via the service-role PostgREST client (not through a SECURITY DEFINER function), so
-- service_role needs real table grants — CREATE TABLE alone doesn't grant anything to other roles.
-- No grant to `authenticated`: this table has no RLS policies, so that would let any logged-in
-- user read/write any row directly, bypassing the edge functions' authorization checks.
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.internal_user_branches TO service_role;
