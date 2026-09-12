-- A Company Admin gives a user a role, and says which.
--
-- Adding somebody to a company has meant choosing between three shapes the code inferred a role
-- from: a workshop user became Client Admin, a branch user became Branch Manager, a company user
-- became Internal Branch User. That covers the common cases and cannot express the others — a
-- Service Advisor, or a second Company Admin — and it left the role as something that happened to
-- an account rather than something anyone decided.
--
-- The assignable set is the one the permissions module already uses: permission_roles, plus
-- Company Admin, which a Company Admin may hand to someone else in their own company. Qparts Admin
-- is not in it. That is the platform's role, and a company handing it out would be a company
-- granting itself the platform.
--
-- The derivation stays for accounts nobody has chosen a role for, so nothing changes for the users
-- created before this. What it no longer does is overwrite a deliberate choice: editing somebody's
-- branches used to silently reset their role, which is the bug this half of the migration fixes.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_assignable_roles()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'role_id', r.role_id, 'role_name', r.role_name, 'sort_order', r.sort_order,
             'is_admin_role', r.is_admin_role)
           ORDER BY r.sort_order, r.role_name)
    FROM (
      SELECT pr.role_id, ld.list_data AS role_name, pr.sort_order, false AS is_admin_role
        FROM qvm_new_apps.permission_roles pr
        JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id
       WHERE pr.is_assignable
      UNION ALL
      -- Runs the company. Offered last, and marked, because it is not a job title like the others:
      -- it hands over everything the person granting it has.
      SELECT ld.list_data_id, ld.list_data, 900, true
        FROM qvm_new_apps.list_data ld
       WHERE ld.list_data_id = qvm_new_apps.company_admin_role_id()
    ) r), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.admin_assignable_roles() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_assignable_roles() $$;

REVOKE ALL ON FUNCTION public.admin_assignable_roles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_assignable_roles() TO authenticated;

-- Changing the role of somebody who already exists.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_user_role(p_user_id uuid, p_role_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_type int; v_ok boolean;
BEGIN
  SELECT user_type INTO v_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  -- Every company this person belongs to has to be one the caller administers. Without that, an
  -- id from anywhere would be a way to reach into another company's staff.
  IF qvm_new_apps.is_qparts_admin(v_uid) THEN
    v_ok := true;
  ELSE
    v_ok := qvm_new_apps.is_company_admin(v_uid)
        AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_companies(p_user_id))
        AND NOT EXISTS (
              SELECT 1 FROM qvm_new_apps.permission_companies(p_user_id) c
               WHERE NOT qvm_new_apps.can_admin_company(c.company_id));
  END IF;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to administer');
  END IF;

  IF NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(qvm_new_apps.admin_assignable_roles()->'data') r
        WHERE (r->>'role_id')::int = p_role_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role cannot be assigned');
  END IF;

  UPDATE qvm_new_apps.user_data
     SET user_role = p_role_id, updated_at = now()
   WHERE user_id = p_user_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user_id', p_user_id, 'user_role', p_role_id));
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_role(p_user_id uuid, p_role_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_user_role(p_user_id, p_role_id) $$;

REVOKE ALL ON FUNCTION public.admin_set_user_role(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_role(uuid, integer) TO authenticated;

-- ─────────────────────────────────────────── the scope edit stops overwriting a chosen role

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_user_scope(p_user_id uuid, p_workshop_ids bigint[] DEFAULT NULL::bigint[], p_branches jsonb DEFAULT NULL::jsonb, p_company_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_type int;
  v_company integer;
  v_is_workshop_user boolean;
BEGIN
  -- A Company Admin may place people inside their own company: every workshop and every company
  -- named has to be one they administer, and the user they are moving must already be reachable
  -- from there — otherwise this call would be a way to adopt somebody else's account.
  IF NOT (qvm_new_apps.is_qparts_admin_or_service()
          OR (qvm_new_apps.is_company_admin(auth.uid())
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_workshop(w))
                              FROM unnest(COALESCE(p_workshop_ids, ARRAY[]::bigint[])) w), true)
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c))
                              FROM unnest(COALESCE(p_company_ids, ARRAY[]::integer[])) c), true)
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_branch((b->>'customer_id')::int))
                              FROM jsonb_array_elements(COALESCE(p_branches, '[]'::jsonb)) b), true))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: that is outside your company');
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
  -- Deriving the role from the scope was right while nobody could choose one. A Company Admin can
  -- now assign a role deliberately, so the derivation only fills a gap: an account already holding
  -- a role someone picked from the assignable set keeps it, whatever its scope now looks like.
  -- Otherwise editing somebody's branches would quietly undo the role they were given.
  IF NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.user_data ud
        WHERE ud.user_id = p_user_id
          AND (ud.user_role IN (172) OR ud.user_role = qvm_new_apps.company_admin_role_id()
               OR EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles pr
                           WHERE pr.role_id = ud.user_role AND pr.is_assignable))
     ) THEN
    IF v_type = 183 THEN
      v_is_workshop_user := EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id);
      UPDATE qvm_new_apps.user_data
      SET user_role = CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END,
          updated_at = now()
      WHERE user_id = p_user_id AND user_role <> CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END;
    ELSIF v_type = 185
          AND EXISTS (SELECT 1 FROM qvm_new_apps.user_companies WHERE user_id = p_user_id) THEN
      UPDATE qvm_new_apps.user_data
      SET user_role = 271, updated_at = now()
      WHERE user_id = p_user_id;
    END IF;
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
END $function$;;
