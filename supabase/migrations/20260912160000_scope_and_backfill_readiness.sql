-- Two things the first test of the new context turned up.
--
-- ONE. A Qparts Admin came back as scope-restricted. effective_branch_ids folded user_data.user_branch
-- into the union for everyone, and an internal account that happens to carry one — most do, it is a
-- leftover default from before internal_user_branches existed — was therefore pinned to that single
-- branch. For an internal user the scope is what has been EXPLICITLY assigned: internal_user_branches
-- and user_workshops. Nothing assigned means no restriction, which is what NULL says.
--
-- TWO. Branches created before the provisioning existed have no region and no account manager, so
-- the first order raised on one fails with a message that names neither. They are provisioned here.

CREATE OR REPLACE FUNCTION qvm_new_apps.effective_branch_ids(p_user_id uuid)
RETURNS integer[] LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_type int;
  v_branch int;
  v_ids integer[];
BEGIN
  SELECT user_type, user_branch INTO v_type, v_branch
  FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_type IS NULL THEN RETURN ARRAY[]::integer[]; END IF;

  IF v_type = 185 THEN
    -- Internal: only what someone deliberately assigned.
    SELECT array_agg(DISTINCT b) INTO v_ids FROM (
      SELECT iub.branch_id AS b FROM qvm_new_apps.internal_user_branches iub WHERE iub.user_id = p_user_id
      UNION
      SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
        JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
       WHERE uw.user_id = p_user_id
    ) s WHERE b IS NOT NULL;
    RETURN v_ids;            -- NULL when nothing is assigned: unrestricted
  END IF;

  -- Client side: the branches they hold, the branches of their workshops, and the single branch on
  -- their profile, which for these accounts IS their scope rather than a leftover.
  SELECT array_agg(DISTINCT b) INTO v_ids FROM (
    SELECT ub.client_branch_id AS b FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id
    UNION
    SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
      JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
     WHERE uw.user_id = p_user_id
    UNION
    SELECT v_branch WHERE v_branch IS NOT NULL
  ) s WHERE b IS NOT NULL;

  RETURN COALESCE(v_ids, ARRAY[]::integer[]);
END $$;

-- Everything that already exists, brought up to the same standard. Idempotent: a branch that is
-- already provisioned is left alone, and one with nothing to copy an account manager from is
-- reported by branch_quotation_readiness rather than guessed at.
DO $backfill$
DECLARE r record; v_done int := 0;
BEGIN
  FOR r IN SELECT customer_id FROM qvm_new_apps.client_branches ORDER BY customer_id LOOP
    PERFORM qvm_new_apps.provision_branch_for_quotations(r.customer_id);
    v_done := v_done + 1;
  END LOOP;
  RAISE NOTICE 'provisioned % branches', v_done;
END $backfill$;
