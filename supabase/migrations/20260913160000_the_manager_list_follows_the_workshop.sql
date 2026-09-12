-- The manager list follows the workshop on screen.
--
-- Choosing a workshop narrowed the branches and left the dropdown offering every eligible person in
-- the caller's reach — for a Qparts Admin, everyone on the platform. Assigning a branch means
-- picking from the people who work at that workshop, so that is what the list holds now: whoever is
-- attached to the workshop, holds one of its branches, or reaches it through their company.
--
-- The exception is anyone already in its allocation grid. They stay listed whatever their
-- attachment says, because a dropdown that cannot show the value already saved in a slot renders it
-- as blank and invites someone to overwrite it by accident.
--
-- The argument is added by dropping the one-argument version rather than defaulting alongside it:
-- PostgREST cannot choose between two functions when the call names only the arguments they share.

DROP FUNCTION IF EXISTS public.list_account_managers(uuid);

CREATE OR REPLACE FUNCTION public.list_account_managers(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_scope integer[];
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185
           OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager'))
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_scope := qvm_new_apps.get_internal_branch_scope(v_uid);

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      u.user_id AS id,
      COALESCE(NULLIF(btrim(u.user_name), ''), u.email)::text AS name,
      r.list_data::text AS role_name,
      EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
               WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                                   a.second_substitute, a.fallback_account_manager)) AS is_allocated,
      -- Counted within the chosen workshop, so "3 branches" answers the question actually being
      -- asked on this screen rather than one about the whole platform.
      (SELECT count(DISTINCT a.customer_id)
         FROM qvm_new_apps.account_manager_branches a
         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = a.customer_id
        WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                            a.second_substitute, a.fallback_account_manager)
          AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id))::int AS branch_count
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data r ON r.list_data_id = u.user_role
    WHERE (
            -- The roles that staff a branch, by name: the ids differ per environment.
            lower(btrim(r.list_data)) IN ('branch manager', 'client admin', 'qparts admin')
            -- Anyone already holding a slot stays listed whatever their role says, so an existing
            -- allocation can never point at a name the dropdown cannot show.
            OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
                        WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                                            a.second_substitute, a.fallback_account_manager))
          )
      AND (
            v_scope IS NULL
            OR qvm_new_apps.effective_branch_ids(u.user_id) && v_scope
          )
      -- With a workshop chosen, the list is that workshop's people: whoever is attached to the
      -- workshop itself, whoever holds one of its branches, and whoever already appears in its
      -- allocation grid — that last one so an existing assignment never points at a name the
      -- dropdown has just filtered away.
      AND (
            p_workshop_id IS NULL
            OR EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                        WHERE uw.user_id = u.user_id AND uw.workshop_id = p_workshop_id)
            OR EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub
                         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ub.client_branch_id
                        WHERE ub.user_id = u.user_id AND cb.workshop_id = p_workshop_id)
            OR EXISTS (SELECT 1 FROM qvm_new_apps.internal_user_branches iub
                         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = iub.branch_id
                        WHERE iub.user_id = u.user_id AND cb.workshop_id = p_workshop_id)
            OR EXISTS (SELECT 1 FROM qvm_new_apps.user_companies uc
                         JOIN qvm_new_apps.workshop_companies wc ON wc.company_id = uc.company_id
                        WHERE uc.user_id = u.user_id AND wc.workshop_id = p_workshop_id)
            OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches a
                         JOIN qvm_new_apps.client_branches cb ON cb.customer_id = a.customer_id
                        WHERE cb.workshop_id = p_workshop_id
                          AND u.user_id IN (a.main_account_manager, a.first_substitute,
                                            a.second_substitute, a.fallback_account_manager))
          )
  ) x;

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION public.list_account_managers(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_account_managers(uuid, bigint) TO authenticated;
