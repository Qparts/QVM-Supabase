-- Synced from QVM/test branch applied migration history (version 20260407092039, name: qpd562_add_pick_overloads)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public._pick_available_manager(
  p_branch_id int,
  p_slot int,
  p_date date
) RETURNS uuid
LANGUAGE sql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT public._pick_available_manager(p_branch_id, p_slot::smallint, p_date);
$$;

CREATE OR REPLACE FUNCTION public._pick_available_manager_weekly(
  p_branch_id int,
  p_slot int,
  p_date date
) RETURNS uuid
LANGUAGE sql STABLE
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT public._pick_available_manager_weekly(p_branch_id, p_slot::smallint, p_date);
$$;

COMMIT;;
