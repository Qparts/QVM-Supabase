-- Synced from QVM/test branch applied migration history (version 20260517094329, name: drop_legacy_get_internal_dashboard_with_p_view)
DROP FUNCTION IF EXISTS public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], text, text, integer, integer);;
