-- What this user may do, and the one place that answers it.
--
-- Three callers need the same answer and must not each work it out: the sidebar draws itself from
-- it, the route guard refuses navigation with it, and the write RPCs raise on it. Hiding a button
-- has never stopped anyone, so the third is the one that actually enforces — the first two exist so
-- people are not offered work the server will refuse.
--
-- Resolution, in order:
--
--   1. Qparts Admin and Company Admin get everything. Asked first, so no lookup can take it away.
--   2. A user with companies takes the union of what those companies grant their role. A workshop
--      serving two companies gives its people two, and permitted-by-either is the only rule the
--      sidebar can use — it is drawn long before anyone picks which company an order is for.
--   3. A user with no company — Qparts staff — falls back to the role defaults, which is exactly
--      the static map they have today.
--   4. A role nobody has written rules for is unrestricted, which is how the TypeScript map
--      already behaves when it has no entry for a role. Deny-by-default here would lock out every
--      Qparts operational role on the day this deploys.

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_companies(p_user_id uuid)
RETURNS TABLE (company_id integer) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT uc.company_id FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id
  UNION
  SELECT wc.company_id
    FROM qvm_new_apps.user_workshops uw
    JOIN qvm_new_apps.workshop_companies wc ON wc.workshop_id = uw.workshop_id
   WHERE uw.user_id = p_user_id
  UNION
  SELECT wc.company_id
    FROM qvm_new_apps.user_branches ub
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ub.client_branch_id
    JOIN qvm_new_apps.workshop_companies wc ON wc.workshop_id = cb.workshop_id
   WHERE ub.user_id = p_user_id
  UNION
  -- The single company on the profile, for accounts that predate every table above.
  SELECT ud.user_company FROM qvm_new_apps.user_data ud
   WHERE ud.user_id = p_user_id AND ud.user_company IS NOT NULL;
$$;

/**
 * The whole map for one user: every page they may see, and what they may do on it.
 */
CREATE OR REPLACE FUNCTION qvm_new_apps.page_permissions_for(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_role int;
  v_unrestricted boolean;
  v_has_rules boolean;
  v_has_company boolean;
  v_pages jsonb;
BEGIN
  SELECT user_role INTO v_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('unrestricted', false, 'is_admin', false, 'pages', '{}'::jsonb);
  END IF;

  -- Runs the platform, or runs the company: either way, everything.
  v_unrestricted := qvm_new_apps.is_qparts_admin(p_user_id) OR qvm_new_apps.is_company_admin(p_user_id);

  IF NOT v_unrestricted THEN
    -- A role with no rules anywhere keeps what it has today rather than losing everything.
    SELECT EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles WHERE role_id = v_role AND is_assignable)
      INTO v_has_rules;
    v_unrestricted := NOT v_has_rules;
  END IF;

  IF v_unrestricted THEN
    RETURN jsonb_build_object(
      'unrestricted', true,
      'is_admin', qvm_new_apps.is_qparts_admin(p_user_id) OR qvm_new_apps.is_company_admin(p_user_id),
      'pages', '{}'::jsonb);
  END IF;

  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.permission_companies(p_user_id)) INTO v_has_company;

  SELECT COALESCE(jsonb_object_agg(x.nav_id, jsonb_build_object(
           'view', x.can_view, 'create', x.can_create, 'update', x.can_update, 'delete', x.can_delete)), '{}'::jsonb)
    INTO v_pages
  FROM (
    SELECT p.nav_id,
           bool_or(COALESCE(e.can_view,   d.can_view,   false)) OR p.is_always_on AS can_view,
           bool_or(COALESCE(e.can_create, d.can_create, false)) AS can_create,
           bool_or(COALESCE(e.can_update, d.can_update, false)) AS can_update,
           bool_or(COALESCE(e.can_delete, d.can_delete, false)) AS can_delete
    FROM qvm_new_apps.nav_pages p
    LEFT JOIN qvm_new_apps.nav_page_role_defaults d ON d.nav_id = p.nav_id AND d.role_id = v_role
    -- One row per company the user reaches, so bool_or is the union across them. With no company
    -- there is one NULL row and the defaults stand alone.
    LEFT JOIN LATERAL (
      SELECT c.company_id FROM qvm_new_apps.permission_companies(p_user_id) c
    ) uc ON v_has_company
    LEFT JOIN qvm_new_apps.company_role_permissions e
           ON e.company_id = uc.company_id AND e.role_id = v_role AND e.nav_id = p.nav_id
    WHERE p.is_company_page
    GROUP BY p.nav_id, p.is_always_on
  ) x;

  RETURN jsonb_build_object('unrestricted', false, 'is_admin', false, 'pages', v_pages);
END $$;

CREATE OR REPLACE FUNCTION public.my_page_permissions() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT jsonb_build_object('success', true, 'data',
              qvm_new_apps.page_permissions_for(auth.uid())) $$;

REVOKE ALL ON FUNCTION public.my_page_permissions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_page_permissions() TO authenticated;

/**
 * One question, for the write paths. Cheap enough to call per statement: it reads at most one row
 * per company the caller belongs to.
 */
CREATE OR REPLACE FUNCTION qvm_new_apps.has_page_permission(p_nav_id text, p_action text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_perms jsonb; v_page jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    -- No session: this is the service role acting inside an edge function that has already checked
    -- the user. Its own gate is the authority there, and refusing here would break every one.
    RETURN true;
  END IF;
  v_perms := qvm_new_apps.page_permissions_for(auth.uid());
  IF COALESCE((v_perms->>'unrestricted')::boolean, false) THEN RETURN true; END IF;
  v_page := v_perms->'pages'->p_nav_id;
  IF v_page IS NULL THEN
    -- A page outside the company set is governed by the role checks that were always there.
    RETURN NOT EXISTS (SELECT 1 FROM qvm_new_apps.nav_pages WHERE nav_id = p_nav_id AND is_company_page);
  END IF;
  RETURN COALESCE((v_page->>p_action)::boolean, false);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.require_page_permission(p_nav_id text, p_action text)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NOT qvm_new_apps.has_page_permission(p_nav_id, p_action) THEN
    RAISE EXCEPTION 'Access denied: you may not % on %', p_action, p_nav_id
      USING ERRCODE = '42501';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.has_page_permission(p_nav_id text, p_action text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.has_page_permission(p_nav_id, p_action) $$;

REVOKE ALL ON FUNCTION public.has_page_permission(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_page_permission(text, text) TO authenticated;
