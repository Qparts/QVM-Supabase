-- The view-quotation "Add Part" modal calls public.add_rfq_item with 7 named
-- params (see supabase/migrations/20260105121500_public_add_rfq_item.sql and
-- pages/rfq-dashboard-v3/services/itemApi.ts). An untracked second overload of
-- add_rfq_item (12 params: adds p_main_brand, p_model, p_year,
-- p_is_internal_note, p_require_internal_user) exists live but was never
-- committed as a migration and is not called anywhere in the app. PostgREST
-- can no longer pick a candidate between the two (PGRST203) once both exist.
-- Drop the untracked overload so only the version-controlled, actually-used
-- 7-param signature remains.
DROP FUNCTION IF EXISTS public.add_rfq_item(
  integer, text, text, integer, integer, text, text,
  integer, text, text, boolean, boolean
);
