-- A company user sees their company, not everything.
--
-- Two faults, and together they meant a company-scoped internal user saw every branch in the
-- platform — the opposite of what the account was created for.
--
-- ONE. Twenty-four dashboards and reports resolve scope through get_internal_branch_scope, which
-- reads internal_user_branches and nothing else. A company user's scope lives in user_companies, so
-- that function found no rows, returned NULL, and NULL means "no restriction". The new scopes
-- existed and nothing consulted them.
--
-- TWO, and the more dangerous one: effective_branch_ids returned NULL whenever the branch list came
-- out empty — including for a user who IS assigned, to a company that happens to have no workshops
-- yet. "Assigned to nothing" and "not assigned at all" are opposite answers, and collapsing them
-- into NULL turns a narrow scope into a global one. They are now distinguished: NULL only when the
-- user has no scoping rows whatsoever.

CREATE OR REPLACE FUNCTION qvm_new_apps.effective_branch_ids(p_user_id uuid)
RETURNS integer[] LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_type int;
  v_branch int;
  v_ids integer[];
  v_assigned boolean;
BEGIN
  SELECT user_type, user_branch INTO v_type, v_branch
  FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_type IS NULL THEN RETURN ARRAY[]::integer[]; END IF;

  -- Is this account scoped at all? Asked before the branches are resolved, because a scope that
  -- resolves to nothing is still a scope.
  v_assigned :=
       EXISTS (SELECT 1 FROM qvm_new_apps.internal_user_branches WHERE user_id = p_user_id)
    OR EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops        WHERE user_id = p_user_id)
    OR EXISTS (SELECT 1 FROM qvm_new_apps.user_companies        WHERE user_id = p_user_id)
    OR (v_type <> 185 AND EXISTS (SELECT 1 FROM qvm_new_apps.user_branches WHERE user_id = p_user_id));

  IF v_type = 185 THEN
    SELECT array_agg(DISTINCT b) INTO v_ids FROM (
      SELECT iub.branch_id AS b FROM qvm_new_apps.internal_user_branches iub WHERE iub.user_id = p_user_id
      UNION
      SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
        JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
       WHERE uw.user_id = p_user_id
      UNION
      SELECT cb.customer_id
        FROM qvm_new_apps.user_companies uc
        JOIN qvm_new_apps.workshop_companies wc ON wc.company_id = uc.company_id
        JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = wc.workshop_id
       WHERE uc.user_id = p_user_id
    ) s WHERE b IS NOT NULL;

    IF v_assigned THEN RETURN COALESCE(v_ids, ARRAY[]::integer[]); END IF;
    RETURN NULL;                                  -- genuinely unassigned: no restriction
  END IF;

  SELECT array_agg(DISTINCT b) INTO v_ids FROM (
    SELECT ub.client_branch_id AS b FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id
    UNION
    SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
      JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
     WHERE uw.user_id = p_user_id
    UNION
    SELECT cb.customer_id
      FROM qvm_new_apps.user_companies uc
      JOIN qvm_new_apps.workshop_companies wc ON wc.company_id = uc.company_id
      JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = wc.workshop_id
     WHERE uc.user_id = p_user_id
    UNION
    SELECT v_branch WHERE v_branch IS NOT NULL
  ) s WHERE b IS NOT NULL;

  RETURN COALESCE(v_ids, ARRAY[]::integer[]);      -- a client user is never unrestricted
END $$;

-- One resolver, reached through the name two dozen callers already use. Qparts Admin keeps its
-- explicit exemption: an admin who happens to be assigned somewhere is still an admin, and the old
-- function said so first.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_branch_scope(p_user_id uuid)
RETURNS integer[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO '' AS $function$
  SELECT CASE
    WHEN (SELECT user_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id) = 172 THEN NULL
    ELSE qvm_new_apps.effective_branch_ids(p_user_id)
  END;
$function$;
