-- Synced from QVM/test branch applied migration history (version 20260426103339, name: 20260426102000_qpd417_fix_get_available_manager_slot_returns_boolean)
BEGIN;

-- QPD-417: Redefine get_available_manager_slot to return a boolean instead of a row id
-- This avoids return-type mismatches across environments where account_manager_slots.id type may differ.
DROP FUNCTION IF EXISTS public.get_available_manager_slot(uuid, integer, text);

CREATE FUNCTION public.get_available_manager_slot(
  p_manager_id uuid,
  p_slot_number integer,
  p_day text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_available boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.account_manager_slots ams
    WHERE ams.account_manager = p_manager_id
      AND ams.slot_number = p_slot_number
      AND ams.is_available = true
      AND (
        (lower(p_day) = 'saturday'  AND ams.saturday  = true) OR
        (lower(p_day) = 'sunday'    AND ams.sunday    = true) OR
        (lower(p_day) = 'monday'    AND ams.monday    = true) OR
        (lower(p_day) = 'tuesday'   AND ams.tuesday   = true) OR
        (lower(p_day) = 'wednesday' AND ams.wednesday = true) OR
        (lower(p_day) = 'thursday'  AND ams.thursday  = true)
      )
  ) INTO v_available;

  RETURN COALESCE(v_available, false);
END;
$$;

REVOKE ALL ON FUNCTION public.get_available_manager_slot(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_available_manager_slot(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_available_manager_slot(uuid, integer, text) TO service_role;

COMMIT;
;
