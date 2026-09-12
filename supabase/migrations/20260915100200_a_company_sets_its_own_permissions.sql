-- The Company Admin writes the rules for their own company.
--
-- Read gives the whole matrix in one call — every assignable role against every company page, each
-- cell carrying what is in force and whether that came from the company or from the default. The
-- screen needs the distinction: "this company decided" and "nobody has decided yet" look identical
-- in a checkbox and are not the same fact.
--
-- Write takes the whole matrix back. Cell-at-a-time saving on a grid of several hundred checkboxes
-- means several hundred round trips and a half-applied state whenever one fails; this is one
-- statement that either lands or does not.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_company_permissions(p_company_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_rows jsonb; v_roles jsonb; v_pages jsonb;
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
           'nav_id', p.nav_id, 'label', p.label, 'always_on', p.is_always_on)
         ORDER BY p.sort_order, p.nav_id), '[]'::jsonb) INTO v_pages
    FROM qvm_new_apps.nav_pages p WHERE p.is_company_page;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', x.role_id,
           'nav_id',  x.nav_id,
           'view',    x.can_view,
           'create',  x.can_create,
           'update',  x.can_update,
           'delete',  x.can_delete,
           -- Where this cell came from, so the screen can show a default as a default.
           'is_default', x.is_default)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT pr.role_id, p.nav_id,
           COALESCE(e.can_view,   d.can_view,   false) OR p.is_always_on AS can_view,
           COALESCE(e.can_create, d.can_create, false) AS can_create,
           COALESCE(e.can_update, d.can_update, false) AS can_update,
           COALESCE(e.can_delete, d.can_delete, false) AS can_delete,
           e.company_id IS NULL AS is_default
    FROM qvm_new_apps.permission_roles pr
    CROSS JOIN qvm_new_apps.nav_pages p
    LEFT JOIN qvm_new_apps.nav_page_role_defaults d ON d.role_id = pr.role_id AND d.nav_id = p.nav_id
    LEFT JOIN qvm_new_apps.company_role_permissions e
           ON e.company_id = p_company_id AND e.role_id = pr.role_id AND e.nav_id = p.nav_id
    WHERE pr.is_assignable AND p.is_company_page
  ) x;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'company_id', p_company_id, 'roles', v_roles, 'pages', v_pages, 'cells', v_rows));
END $$;

/**
 * p_cells: [{role_id, nav_id, view, create, update, delete}, …] — the grid as the screen holds it.
 */
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

  -- A cell naming a role the company cannot assign, or a page that is not a company page, is
  -- refused rather than ignored: silently dropping half a save is worse than failing it.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_cells) c
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles pr
                        WHERE pr.role_id = (c->>'role_id')::int AND pr.is_assignable)
        OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.nav_pages p
                        WHERE p.nav_id = c->>'nav_id' AND p.is_company_page)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role or page cannot be given permissions');
  END IF;

  INSERT INTO qvm_new_apps.company_role_permissions
    (company_id, role_id, nav_id, can_view, can_create, can_update, can_delete, updated_by, updated_at)
  SELECT p_company_id,
         (c->>'role_id')::int,
         c->>'nav_id',
         COALESCE((c->>'view')::boolean, false),
         -- An action on a page nobody may open is not a permission, it is a contradiction.
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'create')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'update')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'delete')::boolean, false),
         v_uid, now()
  FROM jsonb_array_elements(p_cells) c
  ON CONFLICT (company_id, role_id, nav_id) DO UPDATE
    SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create,
        can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete,
        updated_by = EXCLUDED.updated_by, updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('saved', v_count));
END $$;

/** Back to the platform defaults for one role, by forgetting what this company said. */
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_reset_company_permissions(
  p_company_id integer,
  p_role_id    integer DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_count int;
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  DELETE FROM qvm_new_apps.company_role_permissions
   WHERE company_id = p_company_id AND (p_role_id IS NULL OR role_id = p_role_id);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('cleared', v_count));
END $$;

CREATE OR REPLACE FUNCTION public.admin_company_permissions(p_company_id integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_company_permissions(p_company_id) $$;

CREATE OR REPLACE FUNCTION public.admin_set_company_permissions(p_company_id integer, p_cells jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_set_company_permissions(p_company_id, p_cells) $$;

CREATE OR REPLACE FUNCTION public.admin_reset_company_permissions(p_company_id integer, p_role_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_reset_company_permissions(p_company_id, p_role_id) $$;

REVOKE ALL ON FUNCTION public.admin_company_permissions(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_company_permissions(integer, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reset_company_permissions(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_company_permissions(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_company_permissions(integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_company_permissions(integer, integer) TO authenticated;
