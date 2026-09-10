-- The Account Managers module works one workshop at a time, and its manager list is no longer empty.
--
-- Two faults, both visible the moment a company-scoped admin opened the page.
--
-- The manager dropdown was empty everywhere. list_account_managers filtered on
-- lower(list_data) IN ('account manager') — a role by that exact name that does not exist in list
-- 16 on any branch. dev has Branch Manager, Client Admin, Qparts Admin and "Qparts Account
-- Manager"; none of them is "Account Manager", so the query matched nobody and every slot on the
-- Branch Assignments tab offered nothing to assign. The list is now the three roles that actually
-- staff a branch — Branch Manager, Client Admin, Qparts Admin — matched by name because the ids
-- are minted per environment, plus anyone already allocated somewhere, who is in the job whatever
-- their role says.
--
-- And the module showed every branch in the platform. The two dashboards read client_branches with
-- no scope at all, which was harmless while Qparts Admin was the only account that could reach the
-- page and is not now that a Company Admin can. Both take the caller's branch scope, and both take
-- a workshop to work on: a flat list of every branch a company owns is not something anyone can
-- assign managers from.
--
-- The dashboards keep their name but not their arity, so the old single-argument versions are
-- dropped rather than left as an overload — PostgREST cannot choose between two functions when the
-- call names only the arguments they share.

-- ─────────────────────────────────────────────────────────────── the workshops one may work on
CREATE OR REPLACE FUNCTION qvm_new_apps.list_manageable_workshops(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_scope integer[] := qvm_new_apps.get_internal_branch_scope(COALESCE(auth.uid(), p_user_id));
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.workshop_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      vw.workshop_id,
      COALESCE(vw.name, 'Workshop ' || vw.workshop_id::text) AS workshop_name,
      (SELECT string_agg(vc.name, ' · ' ORDER BY vc.name)
         FROM qvm_new_apps.workshop_companies wc
         JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = wc.company_id
        WHERE wc.workshop_id = vw.workshop_id) AS company_names,
      (SELECT count(*) FROM qvm_new_apps.client_branches cb WHERE cb.workshop_id = vw.workshop_id)::int
        AS branch_count
    FROM qvm_new_apps.v_client_workshops vw
    WHERE vw.is_active IS DISTINCT FROM false
      AND (
        v_scope IS NULL
        -- A workshop with no branches yet still belongs to whoever owns it: the scope, which is a
        -- list of branches, cannot see it, and it is exactly the workshop someone opens this page
        -- to staff.
        OR EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb
                    WHERE cb.workshop_id = vw.workshop_id AND cb.customer_id = ANY(v_scope))
        OR EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                     JOIN qvm_new_apps.user_companies uc ON uc.company_id = wc.company_id
                    WHERE wc.workshop_id = vw.workshop_id AND uc.user_id = v_uid)
        OR EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                    WHERE uw.workshop_id = vw.workshop_id AND uw.user_id = v_uid)
      )
  ) x;

  RETURN jsonb_build_object('success', true, 'data', v_rows);
END $$;

CREATE OR REPLACE FUNCTION public.list_manageable_workshops(p_user_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_manageable_workshops(p_user_id) $$;

REVOKE ALL ON FUNCTION public.list_manageable_workshops(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manageable_workshops(uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────── who may be assigned to a branch
CREATE OR REPLACE FUNCTION public.list_account_managers(p_user_id uuid)
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
      (SELECT count(DISTINCT a.customer_id) FROM qvm_new_apps.account_manager_branches a
        WHERE u.user_id IN (a.main_account_manager, a.first_substitute,
                            a.second_substitute, a.fallback_account_manager))::int AS branch_count
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
  ) x;

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION public.list_account_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_account_managers(uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────── branch assignments, per workshop
DROP FUNCTION IF EXISTS public.get_account_manager_branches_dashboard(uuid);

CREATE OR REPLACE FUNCTION public.get_account_manager_branches_dashboard(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_can_edit boolean := false;
  v_scope integer[];
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('admin','pricing supervisor'))
  ) INTO v_can_edit;

  v_scope := qvm_new_apps.get_internal_branch_scope(v_uid);

  WITH pivot AS (
    SELECT
      cb.customer_id::int AS branch_id,
      -- The display name is the reader's; branch_key is the raw one, because the CSV import matches
      -- branches by the name in client_branches and would never find a translated one.
      COALESCE(vb.name, cb.branch_name) AS branch_name,
      cb.branch_name AS branch_key,
      cb.workshop_id,
      vw.name AS workshop_name,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s3,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s3,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s3,
      CAST(COALESCE(
        MAX(CASE WHEN amb.slot_number = 1 THEN (amb.fallback_account_manager)::text END),
        MAX(CASE WHEN amb.slot_number = 2 THEN (amb.fallback_account_manager)::text END),
        MAX(CASE WHEN amb.slot_number = 3 THEN (amb.fallback_account_manager)::text END)
      ) AS uuid) AS fallback_user
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = cb.customer_id
    LEFT JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = cb.workshop_id
    LEFT JOIN qvm_new_apps.account_manager_branches amb ON amb.customer_id = cb.customer_id::bigint
    WHERE (v_scope IS NULL OR cb.customer_id = ANY(v_scope))
      AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id)
    GROUP BY cb.customer_id, vb.name, cb.branch_name, cb.workshop_id, vw.name
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      p.branch_id, p.branch_name, p.branch_key, p.workshop_id, p.workshop_name,
      p.main_s1, um1.user_name AS main_s1_name,
      p.main_s2, um2.user_name AS main_s2_name,
      p.main_s3, um3.user_name AS main_s3_name,
      p.sub1_s1, u11.user_name AS sub1_s1_name,
      p.sub1_s2, u12.user_name AS sub1_s2_name,
      p.sub1_s3, u13.user_name AS sub1_s3_name,
      p.sub2_s1, u21.user_name AS sub2_s1_name,
      p.sub2_s2, u22.user_name AS sub2_s2_name,
      p.sub2_s3, u23.user_name AS sub2_s3_name,
      p.fallback_user, uf.user_name AS fallback_user_name
    FROM pivot p
    LEFT JOIN qvm_new_apps.user_data um1 ON um1.user_id = p.main_s1
    LEFT JOIN qvm_new_apps.user_data um2 ON um2.user_id = p.main_s2
    LEFT JOIN qvm_new_apps.user_data um3 ON um3.user_id = p.main_s3
    LEFT JOIN qvm_new_apps.user_data u11 ON u11.user_id = p.sub1_s1
    LEFT JOIN qvm_new_apps.user_data u12 ON u12.user_id = p.sub1_s2
    LEFT JOIN qvm_new_apps.user_data u13 ON u13.user_id = p.sub1_s3
    LEFT JOIN qvm_new_apps.user_data u21 ON u21.user_id = p.sub2_s1
    LEFT JOIN qvm_new_apps.user_data u22 ON u22.user_id = p.sub2_s2
    LEFT JOIN qvm_new_apps.user_data u23 ON u23.user_id = p.sub2_s3
    LEFT JOIN qvm_new_apps.user_data uf  ON uf.user_id  = p.fallback_user
  ) t;

  RETURN jsonb_build_object('can_edit', v_can_edit, 'rows', v_rows);
END $$;

REVOKE ALL ON FUNCTION public.get_account_manager_branches_dashboard(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_branches_dashboard(uuid, bigint) TO authenticated;

-- ─────────────────────────────────────────────────────────────── allocations, same scope and filter
DROP FUNCTION IF EXISTS public.get_account_manager_allocations_dashboard(uuid);

CREATE OR REPLACE FUNCTION public.get_account_manager_allocations_dashboard(
  p_user_id uuid,
  p_workshop_id bigint DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_scope integer[];
  v_rows jsonb := '[]'::jsonb;
  v_last timestamptz := NULL;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_scope := qvm_new_apps.get_internal_branch_scope(v_uid);

  SELECT MAX(calculated_at) INTO v_last FROM qvm_new_apps.account_manager_allocations;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      COALESCE(vb.name, cb.branch_name) AS branch_name,
      cb.workshop_id,
      vw.name AS workshop_name,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.saturday)::text END))::uuid  AS saturday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.saturday)::text END))::uuid  AS saturday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.saturday)::text END))::uuid  AS saturday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.sunday)::text END))::uuid    AS sunday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.sunday)::text END))::uuid    AS sunday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.sunday)::text END))::uuid    AS sunday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.monday)::text END))::uuid    AS monday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.monday)::text END))::uuid    AS monday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.monday)::text END))::uuid    AS monday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.tuesday)::text END))::uuid   AS tuesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.tuesday)::text END))::uuid   AS tuesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.tuesday)::text END))::uuid   AS tuesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.wednesday)::text END))::uuid AS wednesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.wednesday)::text END))::uuid AS wednesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.wednesday)::text END))::uuid AS wednesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.thursday)::text END))::uuid  AS thursday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.thursday)::text END))::uuid  AS thursday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.thursday)::text END))::uuid  AS thursday_s3
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = cb.customer_id
    LEFT JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = cb.workshop_id
    LEFT JOIN qvm_new_apps.account_manager_allocations a ON a.customer_id = cb.customer_id
    WHERE (v_scope IS NULL OR cb.customer_id = ANY(v_scope))
      AND (p_workshop_id IS NULL OR cb.workshop_id = p_workshop_id)
    GROUP BY cb.customer_id, vb.name, cb.branch_name, cb.workshop_id, vw.name
  ) x;

  RETURN jsonb_build_object('rows', v_rows, 'last_calculated_at', v_last);
END $$;

REVOKE ALL ON FUNCTION public.get_account_manager_allocations_dashboard(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_allocations_dashboard(uuid, bigint) TO authenticated;

-- ─────────────────────────────────────────────────────────── an edit stays inside the caller's scope
-- The inline save decided "may this account edit assignments at all" and never "may it edit THIS
-- branch". Everyone who could reach the page was unrestricted, so the question had not come up.
CREATE OR REPLACE FUNCTION qvm_new_apps.assert_am_branch_in_scope(p_user_id uuid, p_branch_id integer)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_scope integer[] := qvm_new_apps.get_internal_branch_scope(p_user_id);
BEGIN
  IF v_scope IS NOT NULL AND NOT (p_branch_id = ANY(v_scope)) THEN
    RAISE EXCEPTION 'Access denied: this branch is not yours to administer';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.upsert_account_manager_branch_inline(
  p_user_id uuid,
  p_branch_id integer,
  p_changes jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_changed text[] := ARRAY[]::text[];
  v_ex_main_s1 uuid; v_ex_main_s2 uuid; v_ex_main_s3 uuid;
  v_ex_sub1_s1 uuid; v_ex_sub1_s2 uuid; v_ex_sub1_s3 uuid;
  v_ex_sub2_s1 uuid; v_ex_sub2_s2 uuid; v_ex_sub2_s3 uuid;
  v_ex_fallback uuid;
  v_new_main_s1 uuid; v_new_main_s2 uuid; v_new_main_s3 uuid;
  v_new_sub1_s1 uuid; v_new_sub1_s2 uuid; v_new_sub1_s3 uuid;
  v_new_sub2_s1 uuid; v_new_sub2_s2 uuid; v_new_sub2_s3 uuid;
  v_new_fallback uuid;
  v_found_id int;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','pricing supervisor')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- ...and that this particular branch is one of theirs.
  PERFORM qvm_new_apps.assert_am_branch_in_scope(p_user_id, p_branch_id);

  SELECT
    CAST(MAX(CASE WHEN slot_number = 1 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (second_substitute)::text END) AS uuid),
    CAST(COALESCE(
      MAX(CASE WHEN slot_number = 1 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 2 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 3 THEN (fallback_account_manager)::text END)
    ) AS uuid)
  INTO
    v_ex_main_s1, v_ex_main_s2, v_ex_main_s3,
    v_ex_sub1_s1, v_ex_sub1_s2, v_ex_sub1_s3,
    v_ex_sub2_s1, v_ex_sub2_s2, v_ex_sub2_s3,
    v_ex_fallback
  FROM qvm_new_apps.account_manager_branches
  WHERE customer_id = p_branch_id::bigint;

  v_new_main_s1 := NULLIF(p_changes->>'main_s1','')::uuid;
  v_new_main_s2 := NULLIF(p_changes->>'main_s2','')::uuid;
  v_new_main_s3 := NULLIF(p_changes->>'main_s3','')::uuid;
  v_new_sub1_s1 := NULLIF(p_changes->>'sub1_s1','')::uuid;
  v_new_sub1_s2 := NULLIF(p_changes->>'sub1_s2','')::uuid;
  v_new_sub1_s3 := NULLIF(p_changes->>'sub1_s3','')::uuid;
  v_new_sub2_s1 := NULLIF(p_changes->>'sub2_s1','')::uuid;
  v_new_sub2_s2 := NULLIF(p_changes->>'sub2_s2','')::uuid;
  v_new_sub2_s3 := NULLIF(p_changes->>'sub2_s3','')::uuid;
  v_new_fallback := NULLIF(p_changes->>'fallback_user','')::uuid;

  IF p_changes ? 'main_s1' THEN
    IF v_new_main_s1 IS DISTINCT FROM v_ex_main_s1 THEN v_changed := array_append(v_changed, 'main_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_main_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s2' THEN
    IF v_new_main_s2 IS DISTINCT FROM v_ex_main_s2 THEN v_changed := array_append(v_changed, 'main_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_main_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s3' THEN
    IF v_new_main_s3 IS DISTINCT FROM v_ex_main_s3 THEN v_changed := array_append(v_changed, 'main_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_main_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s1' THEN
    IF v_new_sub1_s1 IS DISTINCT FROM v_ex_sub1_s1 THEN v_changed := array_append(v_changed, 'sub1_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub1_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s2' THEN
    IF v_new_sub1_s2 IS DISTINCT FROM v_ex_sub1_s2 THEN v_changed := array_append(v_changed, 'sub1_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub1_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s3' THEN
    IF v_new_sub1_s3 IS DISTINCT FROM v_ex_sub1_s3 THEN v_changed := array_append(v_changed, 'sub1_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub1_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s1' THEN
    IF v_new_sub2_s1 IS DISTINCT FROM v_ex_sub2_s1 THEN v_changed := array_append(v_changed, 'sub2_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub2_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s2' THEN
    IF v_new_sub2_s2 IS DISTINCT FROM v_ex_sub2_s2 THEN v_changed := array_append(v_changed, 'sub2_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub2_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s3' THEN
    IF v_new_sub2_s3 IS DISTINCT FROM v_ex_sub2_s3 THEN v_changed := array_append(v_changed, 'sub2_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub2_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'fallback_user' THEN
    IF v_new_fallback IS DISTINCT FROM v_ex_fallback THEN v_changed := array_append(v_changed, 'fallback_user'); END IF;
    UPDATE qvm_new_apps.account_manager_branches
    SET fallback_account_manager = v_new_fallback, updated_at = now()
    WHERE customer_id = p_branch_id::bigint;
    IF NOT FOUND THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, fallback_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_fallback, now(), now());
    END IF;
  END IF;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status','success','changed', v_changed);
END;
$$;
