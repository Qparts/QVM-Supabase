-- Roles are made where they are used, and a vendor is granted from the vendor's own menu.
--
-- Two things the first cut got wrong in practice.
--
-- 1. An internal person who manages a vendor holds internal pages, not vendor pages, so "grant
--    only what you hold" left them nothing to grant on a vendor account. Across portals the rule
--    cannot be one's own pages; it is the page set of that portal's top role — what a Vendor Admin
--    sees, or for a vendor administering its customers' people, what a Customer Admin sees. The
--    scope check still decides WHO may be managed; only the ceiling changes shape.
--
-- 2. Roles were a fixed list. A vendor wants a role of its own — say, a bookkeeper who sees
--    invoices and the statement and nothing else — and a company wants the same for its
--    workshops. A role can now be created by whoever administers a node, is OWNED by that node
--    (a vendor's role is that vendor's, a company's role is that company's), carries its page
--    set as role defaults, and can be given only to people inside the owner's subtree by someone
--    who administers it. The Qparts Admin's roles are global. Built-in roles stay as they are and
--    are still managed by migrations.

------------------------------------------------------------------------------ roles carry an owner

ALTER TABLE qvm_new_apps.permission_roles
  ADD COLUMN IF NOT EXISTS owner_kind text,
  ADD COLUMN IF NOT EXISTS owner_id   bigint,
  ADD COLUMN IF NOT EXISTS created_by uuid;

-- A role name is a value in list 16, so it must be unique there: two "Bookkeeper" rows would be
-- indistinguishable everywhere the name is shown.
CREATE UNIQUE INDEX IF NOT EXISTS user_role_name_uk
  ON qvm_new_apps.list_data (lower(btrim(list_data))) WHERE list_id = 16;

------------------------------------------------------------------------------ one expansion of the ladder

-- A node and everything beneath it. Company: its workshops, their branches, its vendors, their
-- branches, and the customers either owns. Workshop: its branches and customers. Vendor: its
-- branches and customers. Branch, vendor branch, customer: themselves.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_node_descendants(p_kind text, p_node_id bigint)
RETURNS TABLE(kind text, node_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  WITH companies AS (SELECT p_node_id::integer AS company_id WHERE p_kind = 'company'),
  workshops AS (
    SELECT p_node_id AS workshop_id WHERE p_kind = 'workshop'
    UNION SELECT wc.workshop_id FROM qvm_new_apps.workshop_companies wc JOIN companies c ON c.company_id = wc.company_id
  ),
  vendors AS (
    SELECT p_node_id::integer AS vendor_id WHERE p_kind = 'vendor'
    UNION SELECT vc.vendor_id FROM qvm_new_apps.vendor_companies vc JOIN companies c ON c.company_id = vc.company_id
  ),
  branches AS (
    SELECT p_node_id::integer AS customer_id WHERE p_kind = 'branch'
    UNION SELECT cb.customer_id FROM qvm_new_apps.client_branches cb JOIN workshops w ON w.workshop_id = cb.workshop_id
  ),
  vendor_branches AS (
    SELECT p_node_id AS vendor_branch_id WHERE p_kind = 'vendor_branch'
    UNION SELECT vb.vendor_branch_id FROM qvm_new_apps.vendor_branches vb JOIN vendors v ON v.vendor_id = vb.vendor_id
  ),
  customers AS (
    SELECT p_node_id AS end_customer_id WHERE p_kind = 'customer'
    UNION SELECT o.end_customer_id FROM qvm_new_apps.end_customer_owners o
     WHERE (o.workshop_id IS NOT NULL AND o.workshop_id IN (SELECT workshop_id FROM workshops))
        OR (o.vendor_id   IS NOT NULL AND o.vendor_id   IN (SELECT vendor_id FROM vendors))
  )
  SELECT 'company', company_id::bigint FROM companies
  UNION ALL SELECT 'workshop', workshop_id FROM workshops
  UNION ALL SELECT 'branch', customer_id::bigint FROM branches
  UNION ALL SELECT 'vendor', vendor_id::bigint FROM vendors
  UNION ALL SELECT 'vendor_branch', vendor_branch_id FROM vendor_branches
  UNION ALL SELECT 'customer', end_customer_id FROM customers;
$$;

-- The nodes a person's OWN level gives them: the roots of what they administer.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_root_nodes(p_user_id uuid)
RETURNS TABLE(kind text, node_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT 'company', uc.company_id::bigint FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id
  UNION
  SELECT 'workshop', uw.workshop_id FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = p_user_id
  UNION
  SELECT 'branch', ub.client_branch_id::bigint FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id
  UNION
  SELECT 'branch', ud.user_branch::bigint FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_branch IS NOT NULL
  UNION
  SELECT 'vendor', ud.user_vendor::bigint FROM qvm_new_apps.user_data ud
   WHERE ud.user_id = p_user_id AND ud.user_vendor IS NOT NULL
     AND ud.user_role = qvm_new_apps.role_id_by_name('Vendor Admin')
  UNION
  SELECT 'vendor_branch', vbu.vendor_branch_id FROM qvm_new_apps.vendor_branch_users vbu WHERE vbu.user_id = p_user_id
  UNION
  SELECT 'customer', ecu.end_customer_id FROM qvm_new_apps.end_customer_users ecu WHERE ecu.user_id = p_user_id;
$$;

-- Same answer as before, now built from the one expansion.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_admin_nodes(p_user_id uuid)
RETURNS TABLE(kind text, node_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT DISTINCT d.kind, d.node_id
    FROM qvm_new_apps.permission_root_nodes(p_user_id) r
    CROSS JOIN LATERAL qvm_new_apps.permission_node_descendants(r.kind, r.node_id) d;
$$;

------------------------------------------------------------------------------ the ceiling, per portal

-- What a grantor may hand out on a target in portal p_portal. Inside their own portal: their own
-- pages. Across portals: the top role of that portal — the Vendor Admin's menu for a vendor
-- account, the Customer Admin's menu for a customer's person. The two admin roles keep everything
-- a company may give; the Qparts Admin keeps everything.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_ceiling(p_user_id uuid, p_portal text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_pages jsonb; v_own text; v_top_role int;
  v_all jsonb := jsonb_build_object('view', true, 'create', true, 'update', true, 'delete', true);
BEGIN
  v_own := qvm_new_apps.permission_portal_of(p_user_id);
  p_portal := COALESCE(p_portal, v_own);
  IF qvm_new_apps.is_qparts_admin(p_user_id) THEN
    SELECT jsonb_object_agg(nav_id, v_all) INTO v_pages FROM qvm_new_apps.permission_pages
     WHERE portal = p_portal AND nav_id NOT IN ('permissions', 'vendor-permissions');
    RETURN COALESCE(v_pages, '{}'::jsonb);
  END IF;
  IF qvm_new_apps.is_company_admin(p_user_id) THEN
    SELECT jsonb_object_agg(nav_id, v_all) INTO v_pages FROM qvm_new_apps.permission_pages
     WHERE portal = p_portal AND is_company_page AND nav_id NOT IN ('permissions', 'vendor-permissions');
    RETURN COALESCE(v_pages, '{}'::jsonb);
  END IF;
  IF p_portal = v_own THEN
    SELECT COALESCE(jsonb_object_agg(k, v - 'source'), '{}'::jsonb) INTO v_pages
      FROM jsonb_each(qvm_new_apps.page_permissions_for(p_user_id)->'pages') AS e(k, v)
     WHERE (v->>'view')::boolean AND k NOT IN ('permissions', 'vendor-permissions');
    RETURN v_pages;
  END IF;
  -- Across portals: the portal's top role, with its actions as the defaults hold them.
  v_top_role := CASE WHEN p_portal = 'vendor' THEN qvm_new_apps.role_id_by_name('Vendor Admin')
                     ELSE qvm_new_apps.role_id_by_name('Customer Admin') END;
  SELECT COALESCE(jsonb_object_agg(x.nav_id, jsonb_build_object(
           'view', x.v, 'create', x.c, 'update', x.u, 'delete', x.d)), '{}'::jsonb)
    INTO v_pages
    FROM (
      SELECT d.nav_id, bool_or(d.can_view) AS v, bool_or(d.can_create) AS c,
             bool_or(d.can_update) AS u, bool_or(d.can_delete) AS d
        FROM qvm_new_apps.permission_role_defaults d
        JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = d.nav_id
       WHERE d.role_id = v_top_role AND pg.portal = p_portal AND d.can_view
       GROUP BY d.nav_id
    ) x;
  RETURN v_pages;
END $$;

-- The same, as a list the screens can draw a matrix from.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_ceiling_pages(p_portal text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('nav_id', pg.nav_id, 'label', pg.label, 'sort_order', pg.sort_order,
                                        'is_always_on', pg.is_always_on, 'ceiling', c.v) ORDER BY pg.sort_order, pg.label)
      FROM jsonb_each(qvm_new_apps.permission_ceiling(auth.uid(), p_portal)) AS c(k, v)
      JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = c.k), '[]'::jsonb));
$$;

------------------------------------------------------------------------------ which roles a caller may give

-- Same portal as the target, not above the caller's level, no Qparts job title unless the caller
-- is the Qparts Admin, Company Admin only from an admin — and an OWNED role only where the caller
-- administers the owner and the target sits inside it.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_assignable_roles_for(p_user_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', pr.role_id, 'role_name', ld.list_data, 'rank', pr.rank, 'sort_order', pr.sort_order,
           'owner_kind', pr.owner_kind, 'owner_id', pr.owner_id,
           'owner_label', CASE WHEN pr.owner_kind IS NULL THEN NULL ELSE qvm_new_apps.permission_node_label(pr.owner_kind, pr.owner_id) END)
           ORDER BY pr.rank, pr.sort_order, ld.list_data), '[]'::jsonb)
    FROM qvm_new_apps.permission_roles pr
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id
   WHERE pr.portal = qvm_new_apps.permission_portal_of(p_user_id)
     AND pr.rank >= qvm_new_apps.permission_rank_of(auth.uid())
     AND pr.role_id <> qvm_new_apps.role_id_by_name('Qparts Admin')
     AND (NOT pr.platform_only OR qvm_new_apps.is_qparts_admin(auth.uid()))
     AND (pr.role_id <> qvm_new_apps.company_admin_role_id()
          OR qvm_new_apps.is_qparts_admin(auth.uid()) OR qvm_new_apps.is_company_admin(auth.uid()))
     AND (pr.owner_kind IS NULL
          OR (
            (qvm_new_apps.is_qparts_admin(auth.uid())
             OR EXISTS (SELECT 1 FROM qvm_new_apps.permission_admin_nodes(auth.uid()) a
                         WHERE a.kind = pr.owner_kind AND a.node_id = pr.owner_id))
            AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_member_nodes(p_user_id) m
                         JOIN qvm_new_apps.permission_node_descendants(pr.owner_kind, pr.owner_id) d
                           ON d.kind = m.kind AND d.node_id = m.node_id)));
$$;

------------------------------------------------------------------------------ the matrix and the writers use the portal ceiling

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_user_matrix(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_target jsonb; v_resolved jsonb; v_pages jsonb; v_portal text;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  v_resolved := qvm_new_apps.page_permissions_for(p_user_id);
  v_portal := v_resolved->>'portal';
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid, v_portal);
  SELECT jsonb_build_object('user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
           'user_type', ud.user_type, 'user_role', ud.user_role, 'role_name', ld.list_data,
           'portal', v_portal, 'rank', v_resolved->'rank', 'is_admin', v_resolved->'is_admin',
           'nodes', COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', m.kind, 'id', m.node_id,
                                       'label', qvm_new_apps.permission_node_label(m.kind, m.node_id)))
                               FROM qvm_new_apps.permission_member_nodes(ud.user_id) m), '[]'::jsonb))
    INTO v_target
    FROM qvm_new_apps.user_data ud LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
   WHERE ud.user_id = p_user_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'nav_id', pg.nav_id, 'label', pg.label, 'sort_order', pg.sort_order, 'is_always_on', pg.is_always_on,
           'ceiling', v_ceiling->pg.nav_id,
           'effective', COALESCE(v_resolved->'pages'->pg.nav_id,
                                 jsonb_build_object('view', true, 'create', true, 'update', true, 'delete', true, 'source', 'admin')),
           'user_row', CASE WHEN u.user_id IS NULL THEN NULL ELSE jsonb_build_object(
                         'view', u.can_view, 'create', u.can_create, 'update', u.can_update, 'delete', u.can_delete) END,
           'granted_by', g.user_name, 'granted_at', u.granted_at
         ) ORDER BY pg.sort_order, pg.label), '[]'::jsonb)
    INTO v_pages
    FROM qvm_new_apps.permission_pages pg
    LEFT JOIN qvm_new_apps.user_page_permissions u ON u.user_id = p_user_id AND u.nav_id = pg.nav_id
    LEFT JOIN qvm_new_apps.user_data g ON g.user_id = u.granted_by
   WHERE pg.portal = v_portal
     AND v_ceiling ? pg.nav_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user', v_target,
    'editable', NOT COALESCE((v_resolved->>'is_admin')::boolean, false),
    'pages', v_pages,
    'roles', qvm_new_apps.permission_assignable_roles_for(p_user_id),
    'viewer_rank', qvm_new_apps.permission_rank_of(v_uid)));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_set_user(p_user_id uuid, p_cells jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_bad text; v_count int := 0; c jsonb; v_before jsonb; v_after jsonb; v_nav text; v_pg record; v_portal text;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  IF qvm_new_apps.is_qparts_admin(p_user_id) OR qvm_new_apps.is_company_admin(p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'An administrator resolves to everything; change the role instead');
  END IF;
  IF jsonb_typeof(p_cells) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Expected a list of cells');
  END IF;
  v_portal := qvm_new_apps.permission_portal_of(p_user_id);
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid, v_portal);

  SELECT string_agg(DISTINCT x.nav_id, ', ') INTO v_bad
    FROM (
      SELECT btrim(e->>'nav_id') AS nav_id,
             COALESCE((e->>'view')::boolean, false) AS v, COALESCE((e->>'create')::boolean, false) AS c,
             COALESCE((e->>'update')::boolean, false) AS u, COALESCE((e->>'delete')::boolean, false) AS d
        FROM jsonb_array_elements(p_cells) e
    ) x
    LEFT JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = x.nav_id
   WHERE pg.nav_id IS NULL
      OR pg.portal <> v_portal
      OR NOT (v_ceiling ? x.nav_id)
      OR (x.v AND NOT COALESCE((v_ceiling->x.nav_id->>'view')::boolean, false))
      OR (x.c AND NOT COALESCE((v_ceiling->x.nav_id->>'create')::boolean, false))
      OR (x.u AND NOT COALESCE((v_ceiling->x.nav_id->>'update')::boolean, false))
      OR (x.d AND NOT COALESCE((v_ceiling->x.nav_id->>'delete')::boolean, false));
  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot grant more than you hold on: ' || v_bad);
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(p_cells) LOOP
    v_nav := btrim(c->>'nav_id');
    SELECT * INTO v_pg FROM qvm_new_apps.permission_pages WHERE nav_id = v_nav;
    SELECT jsonb_build_object('view', u.can_view, 'create', u.can_create, 'update', u.can_update, 'delete', u.can_delete)
      INTO v_before FROM qvm_new_apps.user_page_permissions u WHERE u.user_id = p_user_id AND u.nav_id = v_nav;
    v_after := jsonb_build_object(
      'view',   v_pg.is_always_on OR COALESCE((c->>'view')::boolean, false),
      'create', COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'create')::boolean, false),
      'update', COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'update')::boolean, false),
      'delete', COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'delete')::boolean, false));
    IF v_before IS NOT DISTINCT FROM v_after THEN CONTINUE; END IF;
    INSERT INTO qvm_new_apps.user_page_permissions (user_id, nav_id, can_view, can_create, can_update, can_delete, granted_by, granted_at)
    VALUES (p_user_id, v_nav, (v_after->>'view')::boolean, (v_after->>'create')::boolean,
            (v_after->>'update')::boolean, (v_after->>'delete')::boolean, v_uid, now())
    ON CONFLICT (user_id, nav_id) DO UPDATE
      SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create,
          can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete,
          granted_by = EXCLUDED.granted_by, granted_at = now();
    INSERT INTO qvm_new_apps.permission_grant_log (target_user_id, kind, nav_id, before, after, granted_by)
    VALUES (p_user_id, 'page', v_nav, v_before, v_after, v_uid);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('saved', v_count));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_reset_user(p_user_id uuid, p_nav_ids text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_count int;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid, qvm_new_apps.permission_portal_of(p_user_id));
  WITH gone AS (
    DELETE FROM qvm_new_apps.user_page_permissions u
     WHERE u.user_id = p_user_id
       AND v_ceiling ? u.nav_id
       AND (p_nav_ids IS NULL OR u.nav_id = ANY (p_nav_ids))
    RETURNING u.nav_id, jsonb_build_object('view', u.can_view, 'create', u.can_create, 'update', u.can_update, 'delete', u.can_delete) AS before
  ), logged AS (
    INSERT INTO qvm_new_apps.permission_grant_log (target_user_id, kind, nav_id, before, after, granted_by)
    SELECT p_user_id, 'reset', g.nav_id, g.before, NULL, v_uid FROM gone g
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM logged;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('cleared', v_count));
END $$;

------------------------------------------------------------------------------ roles made by the people who use them

-- Where a caller's roles live: the Qparts Admin's are global; otherwise the caller's own root
-- node — company, vendor, workshop — and only when they have exactly such a root.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_role_owner_of(p_user_id uuid, OUT kind text, OUT node_id bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF qvm_new_apps.is_qparts_admin(p_user_id) THEN kind := NULL; node_id := NULL; RETURN; END IF;
  SELECT r.kind, r.node_id INTO kind, node_id
    FROM qvm_new_apps.permission_root_nodes(p_user_id) r
   WHERE r.kind IN ('company', 'vendor', 'workshop')
   ORDER BY CASE r.kind WHEN 'company' THEN 1 WHEN 'vendor' THEN 2 ELSE 3 END, r.node_id
   LIMIT 1;
  IF kind IS NULL THEN kind := 'none'; END IF;
END $$;

-- The roles a caller can see for a portal: the built-in and global ones, plus every owned role
-- whose owner the caller administers. Each with its page set, how many people hold it, and
-- whether the caller may edit it.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_roles_for(p_portal text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_roles jsonb; v_owner record;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  p_portal := COALESCE(p_portal, qvm_new_apps.permission_portal_of(v_uid));
  SELECT * INTO v_owner FROM qvm_new_apps.permission_role_owner_of(v_uid);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', pr.role_id, 'role_name', ld.list_data, 'portal', pr.portal, 'rank', pr.rank,
           'platform_only', pr.platform_only, 'can_delegate', pr.can_delegate,
           'owner_kind', pr.owner_kind, 'owner_id', pr.owner_id,
           'owner_label', CASE WHEN pr.owner_kind IS NULL THEN NULL ELSE qvm_new_apps.permission_node_label(pr.owner_kind, pr.owner_id) END,
           'is_custom', pr.created_by IS NOT NULL,
           'editable', pr.created_by IS NOT NULL AND (
                         qvm_new_apps.is_qparts_admin(v_uid)
                         OR (pr.owner_kind IS NOT NULL AND EXISTS (
                               SELECT 1 FROM qvm_new_apps.permission_admin_nodes(v_uid) a
                                WHERE a.kind = pr.owner_kind AND a.node_id = pr.owner_id))),
           'users', (SELECT count(*) FROM qvm_new_apps.user_data ud WHERE ud.user_role = pr.role_id AND ud.deleted_at IS NULL),
           'pages', COALESCE((SELECT jsonb_agg(jsonb_build_object('nav_id', d.nav_id, 'view', d.can_view, 'create', d.can_create,
                                                                  'update', d.can_update, 'delete', d.can_delete) ORDER BY pg.sort_order)
                                FROM qvm_new_apps.permission_role_defaults d
                                JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = d.nav_id
                               WHERE d.role_id = pr.role_id AND d.can_view), '[]'::jsonb)
         ) ORDER BY pr.owner_kind IS NOT NULL, pr.rank, pr.sort_order, ld.list_data), '[]'::jsonb)
    INTO v_roles
    FROM qvm_new_apps.permission_roles pr
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id
   WHERE pr.portal = p_portal
     AND pr.role_id <> qvm_new_apps.role_id_by_name('Qparts Admin')
     AND (pr.owner_kind IS NULL
          OR qvm_new_apps.is_qparts_admin(v_uid)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.permission_admin_nodes(v_uid) a
                      WHERE a.kind = pr.owner_kind AND a.node_id = pr.owner_id));
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'portal', p_portal,
    'can_create', v_owner.kind IS DISTINCT FROM 'none'
                  AND COALESCE((SELECT pr.can_delegate FROM qvm_new_apps.permission_roles pr
                                 JOIN qvm_new_apps.user_data g ON g.user_role = pr.role_id WHERE g.user_id = v_uid), true),
    'owner_kind', v_owner.kind, 'owner_id', v_owner.node_id,
    'owner_label', CASE WHEN v_owner.kind IN ('none') OR v_owner.kind IS NULL THEN NULL
                        ELSE qvm_new_apps.permission_node_label(v_owner.kind, v_owner.node_id) END,
    'roles', v_roles));
END $$;

-- Cells outside the caller's ceiling for that portal, named; NULL when all are inside it.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_cells_outside_ceiling(p_user_id uuid, p_portal text, p_cells jsonb)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  WITH ceiling AS (SELECT qvm_new_apps.permission_ceiling(p_user_id, p_portal) AS c),
  x AS (
    SELECT btrim(e->>'nav_id') AS nav_id,
           COALESCE((e->>'view')::boolean, false) AS v, COALESCE((e->>'create')::boolean, false) AS cr,
           COALESCE((e->>'update')::boolean, false) AS u, COALESCE((e->>'delete')::boolean, false) AS d
      FROM jsonb_array_elements(p_cells) e
  )
  SELECT string_agg(DISTINCT x.nav_id, ', ')
    FROM x
    CROSS JOIN ceiling
    LEFT JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = x.nav_id
   WHERE pg.nav_id IS NULL OR pg.portal <> p_portal OR NOT (ceiling.c ? x.nav_id)
      OR (x.v  AND NOT COALESCE((ceiling.c->x.nav_id->>'view')::boolean, false))
      OR (x.cr AND NOT COALESCE((ceiling.c->x.nav_id->>'create')::boolean, false))
      OR (x.u  AND NOT COALESCE((ceiling.c->x.nav_id->>'update')::boolean, false))
      OR (x.d  AND NOT COALESCE((ceiling.c->x.nav_id->>'delete')::boolean, false));
$$;

-- Makes a role: a name in list 16, a row in permission_roles owned by the caller's root, and its
-- page set as defaults. Ranked one step below the caller — one's own roles are for one's people.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_create_role(p_name text, p_portal text, p_cells jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_owner record; v_bad text; v_role int; v_rank int; v_can boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  IF p_portal NOT IN ('internal', 'vendor') THEN RETURN jsonb_build_object('success', false, 'error', 'Unknown portal'); END IF;
  IF btrim(COALESCE(p_name, '')) = '' THEN RETURN jsonb_build_object('success', false, 'error', 'The role needs a name'); END IF;
  IF jsonb_typeof(p_cells) <> 'array' OR jsonb_array_length(p_cells) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pick at least one page for the role');
  END IF;
  SELECT * INTO v_owner FROM qvm_new_apps.permission_role_owner_of(v_uid);
  v_can := v_owner.kind IS DISTINCT FROM 'none'
       AND COALESCE((SELECT pr.can_delegate FROM qvm_new_apps.permission_roles pr
                      JOIN qvm_new_apps.user_data g ON g.user_role = pr.role_id WHERE g.user_id = v_uid), true);
  IF NOT v_can THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only someone who administers a company, a vendor or a workshop can create roles');
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 16 AND lower(btrim(list_data)) = lower(btrim(p_name))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'A role with that name already exists');
  END IF;
  v_bad := qvm_new_apps.permission_cells_outside_ceiling(v_uid, p_portal, p_cells);
  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot put in a role more than you hold on: ' || v_bad);
  END IF;
  -- One step below the maker inside their own portal; across portals, that portal's user level.
  v_rank := CASE WHEN p_portal <> qvm_new_apps.permission_portal_of(v_uid) THEN 2
                 ELSE LEAST(4, qvm_new_apps.permission_rank_of(v_uid) + 1) END;

  INSERT INTO qvm_new_apps.list_data (list_id, list_data) VALUES (16, btrim(p_name)) RETURNING list_data_id INTO v_role;
  INSERT INTO qvm_new_apps.permission_roles (role_id, sort_order, is_assignable, portal, rank, platform_only, can_delegate, owner_kind, owner_id, created_by)
  VALUES (v_role, 500, (p_portal = 'internal' AND v_owner.kind IS DISTINCT FROM 'workshop'), p_portal, v_rank, false, true,
          NULLIF(v_owner.kind, 'none'), CASE WHEN v_owner.kind = 'none' THEN NULL ELSE v_owner.node_id END, v_uid);
  INSERT INTO qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id, can_view, can_create, can_update, can_delete)
  SELECT 0, v_role, btrim(e->>'nav_id'),
         COALESCE((e->>'view')::boolean, false),
         COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'create')::boolean, false),
         COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'update')::boolean, false),
         COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'delete')::boolean, false)
    FROM jsonb_array_elements(p_cells) e
   WHERE COALESCE((e->>'view')::boolean, false)
  ON CONFLICT (user_type, role_id, nav_id) DO UPDATE
    SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create, can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete;
  -- Profile is everyone's: the role carries it whether or not it was ticked.
  INSERT INTO qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id)
  SELECT 0, v_role, pg.nav_id FROM qvm_new_apps.permission_pages pg WHERE pg.portal = p_portal AND pg.is_always_on
  ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('role_id', v_role, 'role_name', btrim(p_name), 'rank', v_rank));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_update_role(p_role_id integer, p_name text DEFAULT NULL, p_cells jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_pr record; v_bad text;
BEGIN
  SELECT * INTO v_pr FROM qvm_new_apps.permission_roles WHERE role_id = p_role_id;
  IF v_pr.role_id IS NULL OR v_pr.created_by IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only roles made here can be edited');
  END IF;
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid)
          OR (v_pr.owner_kind IS NOT NULL AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_admin_nodes(v_uid) a
                                                       WHERE a.kind = v_pr.owner_kind AND a.node_id = v_pr.owner_id))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this role is not yours to edit');
  END IF;
  IF p_name IS NOT NULL AND btrim(p_name) <> '' THEN
    IF EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 16 AND list_data_id <> p_role_id
                  AND lower(btrim(list_data)) = lower(btrim(p_name))) THEN
      RETURN jsonb_build_object('success', false, 'error', 'A role with that name already exists');
    END IF;
    UPDATE qvm_new_apps.list_data SET list_data = btrim(p_name), updated_at = now() WHERE list_data_id = p_role_id;
  END IF;
  IF p_cells IS NOT NULL THEN
    IF jsonb_typeof(p_cells) <> 'array' OR jsonb_array_length(p_cells) = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Pick at least one page for the role');
    END IF;
    v_bad := qvm_new_apps.permission_cells_outside_ceiling(v_uid, v_pr.portal, p_cells);
    IF v_bad IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'You cannot put in a role more than you hold on: ' || v_bad);
    END IF;
    DELETE FROM qvm_new_apps.permission_role_defaults WHERE role_id = p_role_id;
    INSERT INTO qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id, can_view, can_create, can_update, can_delete)
    SELECT 0, p_role_id, btrim(e->>'nav_id'),
           COALESCE((e->>'view')::boolean, false),
           COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'create')::boolean, false),
           COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'update')::boolean, false),
           COALESCE((e->>'view')::boolean, false) AND COALESCE((e->>'delete')::boolean, false)
      FROM jsonb_array_elements(p_cells) e
     WHERE COALESCE((e->>'view')::boolean, false)
    ON CONFLICT (user_type, role_id, nav_id) DO UPDATE
      SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create, can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete;
    INSERT INTO qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id)
    SELECT 0, p_role_id, pg.nav_id FROM qvm_new_apps.permission_pages pg WHERE pg.portal = v_pr.portal AND pg.is_always_on
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('role_id', p_role_id));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_delete_role(p_role_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_pr record; v_users int;
BEGIN
  SELECT * INTO v_pr FROM qvm_new_apps.permission_roles WHERE role_id = p_role_id;
  IF v_pr.role_id IS NULL OR v_pr.created_by IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only roles made here can be deleted');
  END IF;
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid)
          OR (v_pr.owner_kind IS NOT NULL AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_admin_nodes(v_uid) a
                                                       WHERE a.kind = v_pr.owner_kind AND a.node_id = v_pr.owner_id))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this role is not yours to delete');
  END IF;
  SELECT count(*) INTO v_users FROM qvm_new_apps.user_data WHERE user_role = p_role_id AND deleted_at IS NULL;
  IF v_users > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', format('%s people still hold this role; move them first', v_users));
  END IF;
  DELETE FROM qvm_new_apps.permission_role_defaults WHERE role_id = p_role_id;
  DELETE FROM qvm_new_apps.company_role_permissions WHERE role_id = p_role_id;
  DELETE FROM qvm_new_apps.permission_roles WHERE role_id = p_role_id;
  DELETE FROM qvm_new_apps.list_data WHERE list_data_id = p_role_id AND list_id = 16;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('deleted', p_role_id));
END $$;

------------------------------------------------------------------------------ the public face

CREATE OR REPLACE FUNCTION public.permission_ceiling_pages(p_portal text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_ceiling_pages(p_portal) $$;
CREATE OR REPLACE FUNCTION public.permission_roles_for(p_portal text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_roles_for(p_portal) $$;
CREATE OR REPLACE FUNCTION public.permission_create_role(p_name text, p_portal text, p_cells jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_create_role(p_name, p_portal, p_cells) $$;
CREATE OR REPLACE FUNCTION public.permission_update_role(p_role_id integer, p_name text DEFAULT NULL, p_cells jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_update_role(p_role_id, p_name, p_cells) $$;
CREATE OR REPLACE FUNCTION public.permission_delete_role(p_role_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_delete_role(p_role_id) $$;
