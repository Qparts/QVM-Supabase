-- Roles that mean something, and a user who belongs to a company rather than a workshop.
--
-- Three connected changes:
--
--   1. An account manager is a Branch Manager (195), a Client Admin (170) or a Qparts Admin (172).
--      That is the answer to "who may own a branch's orders", given as roles rather than inferred.
--   2. A client user's role now follows what they actually are, at creation AND whenever their
--      access changes: a workshop user is a Client Admin, a user confined to certain branches is a
--      Branch Manager. Before this, promoting a branch manager to the whole workshop left them
--      carrying role 195, and the role is what the sidebar and the route guard read.
--   3. A company-level user: internal (185), Internal Branch User (271), who sees every branch of
--      every workshop that serves their company — including workshops added later. There was no
--      way to express "this person covers Petromin" short of ticking branches one at a time and
--      re-ticking them whenever a workshop joined.

------------------------------------------------------------------------------ company scope

CREATE TABLE IF NOT EXISTS qvm_new_apps.user_companies (
  user_id    uuid    NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON DELETE CASCADE,
  company_id integer NOT NULL REFERENCES qvm_new_apps.client_companies(company_id) ON DELETE CASCADE,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, company_id)
);
CREATE INDEX IF NOT EXISTS idx_user_companies_company ON qvm_new_apps.user_companies (company_id);

COMMENT ON TABLE qvm_new_apps.user_companies IS
  'Users scoped to a whole company: every branch of every workshop that serves it, now and later.';

-- The scope resolver learns the third source. A company's branches are reached through the
-- workshops that serve it, which is why this cannot be a static list of branch ids.
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
    SELECT array_agg(DISTINCT b) INTO v_ids FROM (
      SELECT iub.branch_id AS b FROM qvm_new_apps.internal_user_branches iub WHERE iub.user_id = p_user_id
      UNION
      SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
        JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
       WHERE uw.user_id = p_user_id
      UNION
      -- Every branch under every workshop serving one of their companies.
      SELECT cb.customer_id
        FROM qvm_new_apps.user_companies uc
        JOIN qvm_new_apps.workshop_companies wc ON wc.company_id = uc.company_id
        JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = wc.workshop_id
       WHERE uc.user_id = p_user_id
    ) s WHERE b IS NOT NULL;
    RETURN v_ids;            -- NULL when nothing is assigned: unrestricted
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

  RETURN COALESCE(v_ids, ARRAY[]::integer[]);
END $$;

------------------------------------------------------------------------------ who may be an account manager

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_account_managers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', u.user_id, 'user_name', u.user_name, 'email', u.email,
             'role_name', u.role_name, 'user_role', u.user_role,
             'is_internal', u.user_type = 185,
             'branch_count', u.branch_count,
             'is_current', u.branch_count > 0)
           ORDER BY u.branch_count DESC, u.user_name)
    FROM (
      SELECT ud.user_id, ud.user_name, ud.email, ud.user_type, ud.user_role, ld.list_data AS role_name,
             (SELECT count(DISTINCT b.customer_id)
                FROM qvm_new_apps.account_manager_branches b
               WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                    b.second_substitute, b.fallback_account_manager)) AS branch_count
      FROM qvm_new_apps.user_data ud
      LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
      -- Branch Manager, Client Admin, Qparts Admin. Anyone already allocated stays listed whatever
      -- their role, because removing them from the list would not remove them from the branches
      -- they already own — it would only hide who is there.
      WHERE ud.deleted_at IS NULL
        AND (ud.user_role IN (195, 170, 172)
             OR EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches b
                         WHERE ud.user_id IN (b.main_account_manager, b.first_substitute,
                                              b.second_substitute, b.fallback_account_manager)))
    ) u
  ), '[]'::jsonb));
END $$;

------------------------------------------------------------------------------ scope keeps the role honest

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_user_scope(
  p_user_id      uuid,
  p_workshop_ids bigint[] DEFAULT NULL,
  p_branches     jsonb    DEFAULT NULL,
  p_company_ids  integer[] DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_type int;
  v_company integer;
  v_is_workshop_user boolean;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin_or_service() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  SELECT user_type INTO v_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  IF p_workshop_ids IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id
       AND NOT (workshop_id = ANY(p_workshop_ids));
    INSERT INTO qvm_new_apps.user_workshops (user_id, workshop_id, created_by)
    SELECT p_user_id, w, v_uid FROM unnest(p_workshop_ids) w
    ON CONFLICT (user_id, workshop_id) DO NOTHING;
  END IF;

  IF p_company_ids IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_companies WHERE user_id = p_user_id
       AND NOT (company_id = ANY(p_company_ids));
    INSERT INTO qvm_new_apps.user_companies (user_id, company_id, created_by)
    SELECT p_user_id, c, v_uid FROM unnest(p_company_ids) c
    ON CONFLICT (user_id, company_id) DO NOTHING;
  END IF;

  IF p_branches IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_branches ub
     WHERE ub.user_id = p_user_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_branches) b
                        WHERE (b->>'customer_id')::int = ub.client_branch_id);
    INSERT INTO qvm_new_apps.user_branches (user_id, client_branch_id, is_manager, created_by)
    SELECT p_user_id, (b->>'customer_id')::int, COALESCE((b->>'is_manager')::boolean, false), v_uid
    FROM jsonb_array_elements(p_branches) b
    ON CONFLICT (user_id, client_branch_id) DO UPDATE SET is_manager = EXCLUDED.is_manager;
  END IF;

  -- The role follows what the person now IS. It is not decoration: the sidebar and the route guard
  -- are built from user_role, so a branch manager promoted to the whole workshop and left on 195
  -- would keep a branch manager's menu.
  IF v_type = 183 THEN
    v_is_workshop_user := EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id);
    UPDATE qvm_new_apps.user_data
    SET user_role = CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END,
        updated_at = now()
    WHERE user_id = p_user_id AND user_role <> CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END;
  ELSIF v_type = 185
        AND EXISTS (SELECT 1 FROM qvm_new_apps.user_companies WHERE user_id = p_user_id) THEN
    -- An internal user scoped to companies is an Internal Branch User: the whole menu, narrowed
    -- data. Qparts Admins are left alone — their reach is the point of the role.
    UPDATE qvm_new_apps.user_data
    SET user_role = 271, updated_at = now()
    WHERE user_id = p_user_id AND user_role NOT IN (172, 271);
  END IF;

  SELECT COALESCE(
    (SELECT w.company_id FROM qvm_new_apps.user_workshops uw
       JOIN qvm_new_apps.client_workshops w ON w.workshop_id = uw.workshop_id
      WHERE uw.user_id = p_user_id LIMIT 1),
    (SELECT uc.company_id FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id LIMIT 1))
  INTO v_company;

  UPDATE qvm_new_apps.user_data ud
  SET user_company = COALESCE(v_company, ud.user_company),
      user_branch  = COALESCE((SELECT ub.client_branch_id FROM qvm_new_apps.user_branches ub
                                WHERE ub.user_id = p_user_id ORDER BY ub.is_manager DESC LIMIT 1),
                              (SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
                                 JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
                                WHERE uw.user_id = p_user_id LIMIT 1),
                              ud.user_branch),
      updated_at = now()
  WHERE ud.user_id = p_user_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user_id', p_user_id,
    'user_role', (SELECT user_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id),
    'branch_ids', to_jsonb(qvm_new_apps.effective_branch_ids(p_user_id))));
END $$;

DROP FUNCTION IF EXISTS public.admin_set_user_scope(uuid, bigint[], jsonb);
CREATE OR REPLACE FUNCTION public.admin_set_user_scope(
  p_user_id uuid, p_workshop_ids bigint[] DEFAULT NULL, p_branches jsonb DEFAULT NULL,
  p_company_ids integer[] DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_set_user_scope(p_user_id, p_workshop_ids, p_branches, p_company_ids); $$;
GRANT EXECUTE ON FUNCTION public.admin_set_user_scope(uuid, bigint[], jsonb, integer[]) TO authenticated;

------------------------------------------------------------------------------ the company's users

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_company_users(p_company_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
             'user_type', ud.user_type, 'user_role', ud.user_role, 'role_name', ld.list_data,
             'branch_count', COALESCE(array_length(qvm_new_apps.effective_branch_ids(ud.user_id), 1), 0))
           ORDER BY ud.user_name)
    FROM qvm_new_apps.user_data ud
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
    JOIN qvm_new_apps.user_companies uc ON uc.user_id = ud.user_id AND uc.company_id = p_company_id
   WHERE ud.deleted_at IS NULL
  ), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.admin_list_company_users(p_company_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_list_company_users(p_company_id); $$;
GRANT EXECUTE ON FUNCTION public.admin_list_company_users(integer) TO authenticated;
