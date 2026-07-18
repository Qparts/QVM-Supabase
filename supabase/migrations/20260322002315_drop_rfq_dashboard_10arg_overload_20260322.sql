-- Synced from QVM/test branch applied migration history (version 20260322002315, name: drop_rfq_dashboard_10arg_overload_20260322)
BEGIN;
-- Remove the ambiguous 10-arg overload to avoid PostgREST ambiguity with the 12-arg version
DROP FUNCTION IF EXISTS public.rfq_dashboard(
  uuid,
  text,
  text,
  text,
  text,
  uuid,
  timestamptz,
  timestamptz,
  integer,
  integer
);
COMMIT;;
