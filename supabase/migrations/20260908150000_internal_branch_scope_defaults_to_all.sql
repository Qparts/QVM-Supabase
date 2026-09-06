-- An internal user with no branch assignment sees everything, not nothing.
--
-- get_internal_branch_scope returned ARRAY[]::integer[] for any internal user who is not Qparts
-- Admin and has no rows in internal_user_branches. Every caller filters with
--   AND (v_branch_scope IS NULL OR cb.customer_id = ANY(v_branch_scope))
-- and `= ANY('{}')` is false for every row, so an empty array is not "no restriction" — it is
-- "match nothing". Those users got an empty internal dashboard and, since 28 other reports read
-- the same function, empty reports across the board.
--
-- Live when this was written: nobody had a single row in internal_user_branches, so every internal
-- user below role 172 was seeing nothing at all.
--
-- COALESCE was doing the damage. array_agg over no rows is already NULL, which is exactly the value
-- every caller reads as "no restriction", so dropping it makes the absence of an assignment mean
-- what it should: an internal user sees every company until someone narrows them, either by
-- assigning branches here or by picking one in the header.
--
-- Assignments still bind when they exist — that is the mechanism the internal-users module uses to
-- limit an Internal Branch User (271) to specific branches.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_branch_scope(p_user_id uuid)
 RETURNS integer[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN (SELECT user_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id) = 172 THEN NULL
    ELSE (
      SELECT array_agg(branch_id)
      FROM qvm_new_apps.internal_user_branches
      WHERE user_id = p_user_id
    )
  END;
$function$;
