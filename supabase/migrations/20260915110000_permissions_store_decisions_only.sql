-- Permissions store what a company decided, and nothing else.
--
-- The first version kept a catalogue: nav_pages listing every governable page, and
-- nav_page_role_defaults holding the platform's answer for each role. Both are dropped here.
--
-- The catalogue only ever earned its keep three ways, and none survives scrutiny. It let the server
-- tell a governed page from an ungoverned one — but the rule that needs is simply "a decision
-- exists or it does not". It validated nav_id on save — but a typo produces a row nothing ever
-- reads, which is not a failure worth a table. And it supplied the matrix its rows — which the
-- frontend already knows, because it draws the sidebar from the same list.
--
-- What it cost was the thing that kept coming up: adding a page to the sidebar meant remembering a
-- migration, and forgetting one left the page missing from every company's matrix with nothing to
-- say so. That trade is not worth making for a validation nobody needs.
--
-- So resolution becomes two cases:
--
--   a row for (company, role, page)  → obey it, on both ends
--   no row                           → behave exactly as before, which is the static menu map and
--                                      whatever role check each function already carries
--
-- Explicit decisions are enforced; silence changes nothing. That is not deny-by-default, and it
-- cannot be: deny-by-default would have locked out every Qparts operational role the day it
-- deployed, which is why the previous version had a defaults table in the first place.
--
-- permission_roles stays. Which roles a company may assign is a real fact about the platform, it
-- does not change when a page is added, and the frontend has no way to know it.

DROP FUNCTION IF EXISTS public.admin_company_permissions(integer);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_company_permissions(integer);

DROP TABLE IF EXISTS qvm_new_apps.nav_page_role_defaults;
DROP TABLE IF EXISTS qvm_new_apps.nav_pages CASCADE;

-- nav_id kept its foreign key to the catalogue; without one it is just the page's name.
ALTER TABLE qvm_new_apps.company_role_permissions
  DROP CONSTRAINT IF EXISTS company_role_permissions_nav_id_fkey;

-- Profile belongs to everyone. With no table to carry the flag it is named here, in the one place
-- that resolves anything, rather than trusted to every screen that might ask.
CREATE OR REPLACE FUNCTION qvm_new_apps.page_permissions_for(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_role int;
  v_pages jsonb;
BEGIN
  SELECT user_role INTO v_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('unrestricted', false, 'is_admin', false, 'pages', '{}'::jsonb);
  END IF;

  IF qvm_new_apps.is_qparts_admin(p_user_id) OR qvm_new_apps.is_company_admin(p_user_id) THEN
    RETURN jsonb_build_object('unrestricted', true, 'is_admin', true, 'pages', '{}'::jsonb);
  END IF;

  -- Only the decisions. A page absent from this map is not restricted — the caller keeps whatever
  -- it had before permissions existed.
  SELECT COALESCE(jsonb_object_agg(x.nav_id, jsonb_build_object(
           'view', x.can_view, 'create', x.can_create, 'update', x.can_update, 'delete', x.can_delete)), '{}'::jsonb)
    INTO v_pages
  FROM (
    SELECT e.nav_id,
           bool_or(e.can_view) OR e.nav_id = 'profile' AS can_view,
           bool_or(e.can_create) AS can_create,
           bool_or(e.can_update) AS can_update,
           bool_or(e.can_delete) AS can_delete
    FROM qvm_new_apps.company_role_permissions e
    -- One row per company the user reaches: two companies through a shared workshop means the
    -- union of what both allow, because the sidebar is drawn before any company is chosen.
    WHERE e.role_id = v_role
      AND e.company_id IN (SELECT c.company_id FROM qvm_new_apps.permission_companies(p_user_id) c)
    GROUP BY e.nav_id
  ) x;

  RETURN jsonb_build_object('unrestricted', false, 'is_admin', false, 'pages', v_pages);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.has_page_permission(p_nav_id text, p_action text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_perms jsonb; v_page jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    -- The service role, inside an edge function that has already identified the user. Its own gate
    -- is the authority there; refusing here would break every one of them.
    RETURN true;
  END IF;
  v_perms := qvm_new_apps.page_permissions_for(auth.uid());
  IF COALESCE((v_perms->>'unrestricted')::boolean, false) THEN RETURN true; END IF;
  v_page := v_perms->'pages'->p_nav_id;
  -- Nobody has decided anything about this page for this role: unchanged from before.
  IF v_page IS NULL THEN RETURN true; END IF;
  RETURN COALESCE((v_page->>p_action)::boolean, false);
END $$;

------------------------------------------------------------------------------ the editor

-- Returns the roles a company may assign and the decisions it has made. The page list comes from
-- the frontend, which draws the sidebar from it and so cannot disagree with itself.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_company_permissions(p_company_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_roles jsonb; v_cells jsonb;
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', pr.role_id, 'role_name', ld.list_data, 'sort_order', pr.sort_order)
         ORDER BY pr.sort_order, ld.list_data), '[]'::jsonb) INTO v_roles
    FROM qvm_new_apps.permission_roles pr
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id
   WHERE pr.is_assignable;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', e.role_id, 'nav_id', e.nav_id,
           'view', e.can_view, 'create', e.can_create,
           'update', e.can_update, 'delete', e.can_delete)), '[]'::jsonb) INTO v_cells
    FROM qvm_new_apps.company_role_permissions e
   WHERE e.company_id = p_company_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'company_id', p_company_id, 'roles', v_roles, 'cells', v_cells));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_company_permissions(
  p_company_id integer,
  p_cells      jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_count int;
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF jsonb_typeof(p_cells) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Expected a list of cells');
  END IF;

  -- The role is still checked: it is a real thing with an id, and a company may only set rules for
  -- the roles it assigns. The page is not — it is the sidebar's own name for a screen, and a name
  -- that matches nothing is a row nothing reads.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_cells) c
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles pr
                        WHERE pr.role_id = (c->>'role_id')::int AND pr.is_assignable)
        OR btrim(COALESCE(c->>'nav_id', '')) = ''
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role cannot be given permissions');
  END IF;

  -- A cell with nothing ticked is not a decision to store: it is the absence of one, and storing it
  -- would mean "denied" where the design says "unchanged". Deleting it is what makes the reset
  -- button and an emptied row mean the same thing.
  DELETE FROM qvm_new_apps.company_role_permissions e
   WHERE e.company_id = p_company_id
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_cells) c
        WHERE (c->>'role_id')::int = e.role_id AND c->>'nav_id' = e.nav_id
          AND NOT COALESCE((c->>'view')::boolean, false)
          AND NOT COALESCE((c->>'create')::boolean, false)
          AND NOT COALESCE((c->>'update')::boolean, false)
          AND NOT COALESCE((c->>'delete')::boolean, false));

  INSERT INTO qvm_new_apps.company_role_permissions
    (company_id, role_id, nav_id, can_view, can_create, can_update, can_delete, updated_by, updated_at)
  SELECT p_company_id,
         (c->>'role_id')::int,
         btrim(c->>'nav_id'),
         COALESCE((c->>'view')::boolean, false),
         -- An action on a page nobody may open is not a permission, it is a contradiction.
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'create')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'update')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'delete')::boolean, false),
         v_uid, now()
  FROM jsonb_array_elements(p_cells) c
  WHERE COALESCE((c->>'view')::boolean, false)
     OR COALESCE((c->>'create')::boolean, false)
     OR COALESCE((c->>'update')::boolean, false)
     OR COALESCE((c->>'delete')::boolean, false)
  ON CONFLICT (company_id, role_id, nav_id) DO UPDATE
    SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create,
        can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete,
        updated_by = EXCLUDED.updated_by, updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('saved', v_count));
END $$;

CREATE OR REPLACE FUNCTION public.admin_company_permissions(p_company_id integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_company_permissions(p_company_id) $$;

REVOKE ALL ON FUNCTION public.admin_company_permissions(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_company_permissions(integer) TO authenticated;
