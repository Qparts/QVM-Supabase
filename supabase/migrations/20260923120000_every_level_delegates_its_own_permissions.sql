-- Every level delegates its own permissions.
--
-- Until now one screen, one grantor: a Company Admin wrote rules for (company, role, page) and
-- nobody else could write any. The company wants the whole ladder to work the way the company
-- does — a workshop sets up its own people, a branch its own, a vendor its own — and it wants the
-- rule that makes that safe: nobody hands out more than they hold.
--
-- The model, in one breath: a PAGE CATALOGUE says what can be granted and in which portal; ROLE
-- DEFAULTS say what a role starts with (the sidebar's own allow-lists, moved server-side so the
-- server can answer "what does this person hold?" without the browser's help); the COMPANY LAYER
-- that already exists stays as the company-wide answer per role; and a new PER-USER LAYER holds
-- what somebody decided for one person. Resolution reads them in that order — user, company,
-- default — and the first that has an opinion wins.
--
-- Who may write the per-user layer for whom:
--   * the target sits at the grantor's level or below, inside a node the grantor administers
--     (their own company/workshop/branch/vendor/customer, or anything beneath it);
--   * the grantor's own effective pages are the ceiling — a page or action the grantor does not
--     hold cannot be granted, cannot be seen on the screen, and is refused server-side;
--   * nobody edits their own record, and the two admin roles resolve to everything before any
--     lookup, so per-user rows never apply to them.
--
-- The Qparts Admin does everything. A Company Admin does everything inside its companies, which
-- includes their workshops, branches, vendors and customers. A vendor grants only vendor-portal
-- pages, because that is all a vendor holds.
--
-- Enforcement in the write RPCs (require_page_permission) keeps its rule: a DECIDED row is
-- obeyed, an undecided page behaves as before. Defaults shape the menu, not the refusals — a
-- default that refused would take away what people were doing yesterday.

------------------------------------------------------------------------------ the page catalogue

CREATE TABLE IF NOT EXISTS qvm_new_apps.permission_pages (
  nav_id          text PRIMARY KEY,
  label           text NOT NULL,
  -- 'internal' is the client/Qparts app, 'vendor' the vendor dashboard. Customers use the
  -- internal app with a two-page menu, so they are a role default, not a portal.
  portal          text NOT NULL CHECK (portal IN ('internal', 'vendor')),
  sort_order      integer NOT NULL DEFAULT 100,
  -- Whether a Company Admin may hand this page out. Platform screens are not theirs to give.
  is_company_page boolean NOT NULL DEFAULT true,
  -- Everyone's, always: view cannot be revoked on either end.
  is_always_on    boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.permission_pages TO service_role;

INSERT INTO qvm_new_apps.permission_pages (nav_id, label, portal, sort_order, is_company_page, is_always_on) VALUES
  ('overview',              'Overview',                    'internal',  10, true,  false),
  ('management-overview',   'Management Overview',         'internal',  20, true,  false),
  ('internal-dashboard',    'Procurement Dashboard',       'internal',  30, true,  false),
  ('supervisor-approvals',  'Supervisor approvals',        'internal',  35, true,  false),
  ('extract-pn',            'Extract Part Number',         'internal',  40, true,  false),
  ('notes',                 'Delivery & Return Notes',     'internal',  50, true,  false),
  ('status-logs',           'Status Logs',                 'internal',  60, true,  false),
  ('purchase-invoices',     'Purchase Orders',             'internal',  70, true,  false),
  ('returns-exchanges',     'Returns & Exchanges',         'internal',  80, true,  false),
  ('performance-reports',   'Performance Reports',         'internal',  90, true,  false),
  ('new-rfq',               'New RFQ',                     'internal', 100, true,  false),
  ('rfqs',                  'RFQs',                        'internal', 110, true,  false),
  ('my-approvals',          'My approvals',                'internal', 115, true,  false),
  ('orders',                'Orders',                      'internal', 120, true,  false),
  ('delivered',             'Delivered Orders',            'internal', 130, true,  false),
  ('shipment-dashboard',    'Shipments',                   'internal', 140, true,  false),
  ('invoices',              'Invoices',                    'internal', 150, true,  false),
  ('statement',             'Statement',                   'internal', 160, true,  false),
  ('supplier-invoices',     'Supplier Invoices',           'internal', 170, true,  false),
  ('supplier-statement',    'Supplier Statement',          'internal', 180, true,  false),
  ('wallet',                'Wallet',                      'internal', 190, true,  false),
  ('integrations',          'Integrations',                'internal', 200, true,  false),
  ('ai-credit',             'AI Credit',                   'internal', 210, true,  false),
  ('parts-pricing-report',  'Parts Pricing',               'internal', 220, true,  false),
  ('archive',               'Notes Archive',               'internal', 230, true,  false),
  ('client-tree',           'Companies & Workshops',       'internal', 300, true,  false),
  ('vendor-tree',           'Vendors & Branches',          'internal', 310, true,  false),
  ('customer-tree',         'Customers & Addresses',       'internal', 320, false, false),
  ('languages',             'Languages',                   'internal', 330, false, false),
  ('client-accounts',       'Client Accounts',             'internal', 340, false, false),
  ('customers',             'Customers',                   'internal', 350, true,  false),
  ('pricing-policies',      'Pricing Policies',            'internal', 360, false, false),
  ('uploaded-data',         'Uploaded Data',               'internal', 370, false, false),
  ('user-mgmt',             'Users & Permissions',         'internal', 380, true,  false),
  ('profit-percentages',    'Profit Percentages',          'internal', 390, false, false),
  ('account-managers',      'Account Managers',            'internal', 400, true,  false),
  ('internal-users',        'Internal Users',              'internal', 410, false, false),
  ('vendors',               'Vendors',                     'internal', 420, true,  false),
  ('webhook-logs',          'Webhook Logs',                'internal', 430, false, false),
  ('appsheet-sync-logs',    'AppSheet Sync Logs',          'internal', 440, false, false),
  ('insurance-companies',   'Insurance Companies',         'internal', 450, true,  false),
  ('send-notification',     'Send Notification',           'internal', 460, true,  false),
  ('notification-rules',    'Notification Rules',          'internal', 470, true,  false),
  ('notification-settings', 'Notification Settings',       'internal', 480, true,  false),
  ('ai-settings',           'AI settings',                 'internal', 490, false, false),
  -- Computed, never stored: view is "this person may delegate", decided by role and scope.
  ('permissions',           'Team permissions',            'internal', 900, true,  false),
  ('profile',               'Profile',                     'internal', 999, true,  true),
  ('vendor-overview',       'Overview',                    'vendor',    10, true,  false),
  ('vendor-quotations',     'Quotations',                  'vendor',    20, true,  false),
  ('vendor-confirmed',      'Confirmed Orders',            'vendor',    30, true,  false),
  ('vendor-uploads',        'Data Upload',                 'vendor',    40, true,  false),
  ('vendor-wallet',         'Wallet',                      'vendor',    50, true,  false),
  ('vendor-branches',       'Branches & Users',            'vendor',    60, true,  false),
  ('vendor-invoices',       'Invoices',                    'vendor',    70, true,  false),
  ('vendor-returns',        'Returns & Exchanges',         'vendor',    80, true,  false),
  ('vendor-statement',      'Statement & Payments',        'vendor',    90, true,  false),
  ('vendor-permissions',    'Team permissions',            'vendor',   900, true,  false),
  ('vendor-profile',        'Vendor Profile',              'vendor',   999, true,  true)
ON CONFLICT (nav_id) DO UPDATE
  SET label = EXCLUDED.label, portal = EXCLUDED.portal, sort_order = EXCLUDED.sort_order,
      is_company_page = EXCLUDED.is_company_page, is_always_on = EXCLUDED.is_always_on;

------------------------------------------------------------------------------ roles carry a level

-- rank: 0 platform, 1 company / vendor, 2 workshop / vendor branch, 3 branch / customer,
-- 4 customer branch. A grantor may assign a role whose rank is not above their own.
-- platform_only: a Qparts job title, handed out by the Qparts Admin alone.
-- can_delegate: whether people in this role may set permissions at all. A switch per role, so
-- taking delegation away from, say, drivers is a row and not a release.
ALTER TABLE qvm_new_apps.permission_roles
  ADD COLUMN IF NOT EXISTS portal        text     NOT NULL DEFAULT 'internal',
  ADD COLUMN IF NOT EXISTS rank          smallint NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS platform_only boolean  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_delegate  boolean  NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION qvm_new_apps.role_id_by_name(p_name text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
   WHERE ld.list_id = 16 AND lower(btrim(ld.list_data)) = lower(btrim(p_name))
   ORDER BY ld.list_data_id LIMIT 1;
$$;

-- Matched by name: role ids are minted per environment. is_assignable and sort_order of the rows
-- the company matrix already uses are left exactly as they are.
INSERT INTO qvm_new_apps.permission_roles (role_id, sort_order, is_assignable, portal, rank, platform_only, can_delegate)
SELECT ld.list_data_id, v.so, v.assignable, v.portal, v.rank, v.platform_only, v.delegate
FROM (VALUES
  ('Qparts Admin',           1, false, 'internal', 0, true,  true),
  ('Company Admin',          5, false, 'internal', 1, false, true),
  ('Qparts Account Manager', 50, false, 'internal', 1, true,  true),
  ('Purchasing',            60, false, 'internal', 1, true,  true),
  ('Part Number Extractor', 70, false, 'internal', 1, true,  true),
  ('Procurement User',      40, true,  'internal', 1, false, true),
  ('Client Admin',          10, true,  'internal', 2, false, true),
  ('Service Advisor',       20, true,  'internal', 3, false, true),
  ('Branch Manager',        30, true,  'internal', 3, false, true),
  ('Driver',                80, false, 'internal', 3, true,  false),
  ('Vendor Admin',         100, false, 'vendor',   1, false, true),
  ('Vendor',               110, false, 'vendor',   2, false, true),
  ('Customer Admin',       200, false, 'internal', 3, false, true),
  ('Customer',             210, false, 'internal', 4, false, false)
) AS v(name, so, assignable, portal, rank, platform_only, delegate)
JOIN qvm_new_apps.list_data ld ON ld.list_id = 16 AND lower(btrim(ld.list_data)) = lower(v.name)
ON CONFLICT (role_id) DO UPDATE
  SET portal = EXCLUDED.portal, rank = EXCLUDED.rank,
      platform_only = EXCLUDED.platform_only, can_delegate = EXCLUDED.can_delegate;

------------------------------------------------------------------------------ what a role starts with

-- The sidebar's allow-lists (config/navAccess.ts), keyed the same way: user_type + role, with
-- user_type 0 meaning "whatever the type". A role with no rows here is unrestricted today and
-- resolves to every page of its portal, which is what it sees now.
CREATE TABLE IF NOT EXISTS qvm_new_apps.permission_role_defaults (
  user_type  integer NOT NULL DEFAULT 0,
  role_id    integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  nav_id     text    NOT NULL REFERENCES qvm_new_apps.permission_pages(nav_id) ON DELETE CASCADE,
  can_view   boolean NOT NULL DEFAULT true,
  can_create boolean NOT NULL DEFAULT true,
  can_update boolean NOT NULL DEFAULT true,
  can_delete boolean NOT NULL DEFAULT true,
  PRIMARY KEY (user_type, role_id, nav_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.permission_role_defaults TO service_role;

INSERT INTO qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id)
SELECT v.user_type, qvm_new_apps.role_id_by_name(v.role_name), n.nav_id
FROM (VALUES
  -- الورشة — Clients / Client Admin
  (183, 'Client Admin', ARRAY['overview','client-tree','purchase-invoices','new-rfq','rfqs','orders','delivered','shipment-dashboard','profile']),
  -- المشتريات — Qparts Team / Client Admin, and Procurement User over fewer branches
  (185, 'Client Admin', ARRAY['overview','management-overview','internal-dashboard','supervisor-approvals','extract-pn','purchase-invoices','returns-exchanges','parts-pricing-report','invoices','supplier-invoices','supplier-statement','wallet','integrations','ai-credit','internal-users','vendors','insurance-companies','send-notification','notification-rules','notification-settings','profile']),
  (185, 'Procurement User', ARRAY['overview','management-overview','internal-dashboard','supervisor-approvals','extract-pn','purchase-invoices','returns-exchanges','parts-pricing-report','invoices','supplier-invoices','supplier-statement','wallet','integrations','ai-credit','internal-users','vendors','insurance-companies','send-notification','notification-rules','notification-settings','profile']),
  -- Company Admin — everything for one company (resolves to unrestricted anyway; this is the
  -- ceiling's and the screen's description of it)
  (0, 'Company Admin', ARRAY['overview','management-overview','internal-dashboard','supervisor-approvals','extract-pn','purchase-invoices','returns-exchanges','parts-pricing-report','invoices','supplier-invoices','supplier-statement','wallet','integrations','ai-credit','vendors','insurance-companies','send-notification','notification-rules','notification-settings','new-rfq','rfqs','orders','delivered','shipment-dashboard','performance-reports','client-tree','vendor-tree','account-managers','user-mgmt','profile']),
  -- An end customer's people: the approvals put to them, and their profile
  (0, 'Customer',       ARRAY['my-approvals','profile']),
  (0, 'Customer Admin', ARRAY['my-approvals','profile']),
  -- The vendor dashboard: the admin has it all, a vendor user has it without Branches & Users
  (205, 'Vendor Admin', ARRAY['vendor-overview','vendor-quotations','vendor-confirmed','vendor-uploads','vendor-wallet','vendor-branches','vendor-invoices','vendor-returns','vendor-statement','vendor-profile']),
  (205, 'Vendor',       ARRAY['vendor-overview','vendor-quotations','vendor-confirmed','vendor-uploads','vendor-wallet','vendor-invoices','vendor-returns','vendor-statement','vendor-profile'])
) AS v(user_type, role_name, navs)
CROSS JOIN LATERAL unnest(v.navs) AS n(nav_id)
WHERE qvm_new_apps.role_id_by_name(v.role_name) IS NOT NULL
  AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_pages p WHERE p.nav_id = n.nav_id)
ON CONFLICT DO NOTHING;

------------------------------------------------------------------------------ the per-user layer

CREATE TABLE IF NOT EXISTS qvm_new_apps.user_page_permissions (
  user_id    uuid    NOT NULL,
  nav_id     text    NOT NULL REFERENCES qvm_new_apps.permission_pages(nav_id) ON DELETE CASCADE,
  can_view   boolean NOT NULL DEFAULT false,
  can_create boolean NOT NULL DEFAULT false,
  can_update boolean NOT NULL DEFAULT false,
  can_delete boolean NOT NULL DEFAULT false,
  granted_by uuid,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, nav_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.user_page_permissions TO service_role;

-- Who changed what for whom. The row above says the current answer; this says how it got there.
CREATE TABLE IF NOT EXISTS qvm_new_apps.permission_grant_log (
  log_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_user_id uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('page', 'role', 'reset')),
  nav_id         text,
  before         jsonb,
  after          jsonb,
  granted_by     uuid,
  granted_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_permission_grant_log_target ON qvm_new_apps.permission_grant_log (target_user_id, granted_at DESC);
GRANT SELECT, INSERT ON qvm_new_apps.permission_grant_log TO service_role;

------------------------------------------------------------------------------ where a person stands

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_portal_of(p_user_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT CASE WHEN ud.user_type = 205 THEN 'vendor' ELSE 'internal' END
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id;
$$;

-- The level a person stands at, from what they belong to — not from their job title. Membership
-- tables decide; the legacy profile columns count only where nothing newer exists.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_rank_of(p_user_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT CASE
    WHEN qvm_new_apps.is_qparts_admin(p_user_id) THEN 0
    WHEN ud.user_type = 205 THEN
      CASE WHEN ud.user_role = qvm_new_apps.role_id_by_name('Vendor Admin') THEN 1 ELSE 2 END
    WHEN ud.user_role = qvm_new_apps.role_id_by_name('Customer Admin') THEN 3
    WHEN ud.user_role = qvm_new_apps.role_id_by_name('Customer') THEN 4
    WHEN qvm_new_apps.is_company_admin(p_user_id)
      OR EXISTS (SELECT 1 FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id) THEN 1
    WHEN EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = p_user_id) THEN 2
    WHEN EXISTS (SELECT 1 FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id)
      OR ud.user_branch IS NOT NULL THEN 3
    -- Qparts staff attached to nothing: company-level people of the platform itself.
    WHEN ud.user_type = 185 THEN 1
    ELSE 3 END
  FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id;
$$;

-- The nodes a person BELONGS to. This is how a grantor finds them.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_member_nodes(p_user_id uuid)
RETURNS TABLE(kind text, node_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT 'company', uc.company_id::bigint FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id
  UNION
  SELECT 'company', ud.user_company::bigint FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_company IS NOT NULL
  UNION
  SELECT 'workshop', uw.workshop_id FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = p_user_id
  UNION
  SELECT 'branch', ub.client_branch_id::bigint FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id
  UNION
  SELECT 'branch', ud.user_branch::bigint FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_branch IS NOT NULL
  UNION
  SELECT 'vendor', ud.user_vendor::bigint FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_vendor IS NOT NULL
  UNION
  SELECT 'vendor_branch', vbu.vendor_branch_id FROM qvm_new_apps.vendor_branch_users vbu WHERE vbu.user_id = p_user_id
  UNION
  SELECT 'customer', ecu.end_customer_id FROM qvm_new_apps.end_customer_users ecu WHERE ecu.user_id = p_user_id;
$$;

-- The nodes a person ADMINISTERS: their own level's nodes and everything beneath them.
-- A company reaches its workshops, their branches, its vendors, their branches, and the customers
-- either owns. A workshop reaches its branches and customers. A vendor admin reaches its branches
-- and customers. A branch, a vendor user, a customer's person reach only their own node.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_admin_nodes(p_user_id uuid)
RETURNS TABLE(kind text, node_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  WITH companies AS (
    SELECT uc.company_id FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id
  ),
  workshops AS (
    SELECT uw.workshop_id FROM qvm_new_apps.user_workshops uw WHERE uw.user_id = p_user_id
    UNION
    SELECT wc.workshop_id FROM qvm_new_apps.workshop_companies wc JOIN companies c ON c.company_id = wc.company_id
  ),
  vendors AS (
    SELECT ud.user_vendor AS vendor_id FROM qvm_new_apps.user_data ud
     WHERE ud.user_id = p_user_id AND ud.user_vendor IS NOT NULL
       AND ud.user_role = qvm_new_apps.role_id_by_name('Vendor Admin')
    UNION
    SELECT vc.vendor_id FROM qvm_new_apps.vendor_companies vc JOIN companies c ON c.company_id = vc.company_id
  ),
  branches AS (
    SELECT ub.client_branch_id AS customer_id FROM qvm_new_apps.user_branches ub WHERE ub.user_id = p_user_id
    UNION
    SELECT ud.user_branch FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_branch IS NOT NULL
    UNION
    SELECT cb.customer_id FROM qvm_new_apps.client_branches cb JOIN workshops w ON w.workshop_id = cb.workshop_id
  ),
  vendor_branches AS (
    SELECT vbu.vendor_branch_id FROM qvm_new_apps.vendor_branch_users vbu WHERE vbu.user_id = p_user_id
    UNION
    SELECT vb.vendor_branch_id FROM qvm_new_apps.vendor_branches vb JOIN vendors v ON v.vendor_id = vb.vendor_id
  ),
  customers AS (
    SELECT ecu.end_customer_id FROM qvm_new_apps.end_customer_users ecu WHERE ecu.user_id = p_user_id
    UNION
    SELECT o.end_customer_id FROM qvm_new_apps.end_customer_owners o
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

CREATE OR REPLACE FUNCTION qvm_new_apps.permission_node_label(p_kind text, p_node_id bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT CASE p_kind
    WHEN 'company'       THEN (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = p_node_id)
    WHEN 'workshop'      THEN COALESCE((SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = p_node_id),
                                       (SELECT w.workshop_code FROM qvm_new_apps.client_workshops w WHERE w.workshop_id = p_node_id))
    WHEN 'branch'        THEN (SELECT cb.branch_name FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = p_node_id)
    WHEN 'vendor'        THEN (SELECT v.vendor_name FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_node_id)
    WHEN 'vendor_branch' THEN (SELECT vb.branch_name FROM qvm_new_apps.vendor_branches vb WHERE vb.vendor_branch_id = p_node_id)
    WHEN 'customer'      THEN (SELECT c.name FROM qvm_new_apps.end_customers c WHERE c.end_customer_id = p_node_id)
  END;
$$;

-- May this grantor set permissions and roles for this target?
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_can_manage(p_grantor uuid, p_target uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT p_grantor IS NOT NULL AND p_target IS NOT NULL AND p_grantor <> p_target
     AND EXISTS (SELECT 1 FROM qvm_new_apps.user_data t WHERE t.user_id = p_target AND t.deleted_at IS NULL)
     AND (
       qvm_new_apps.is_qparts_admin(p_grantor)
       OR (
         NOT qvm_new_apps.is_qparts_admin(p_target)
         AND COALESCE((SELECT pr.can_delegate FROM qvm_new_apps.permission_roles pr
                        JOIN qvm_new_apps.user_data g ON g.user_role = pr.role_id
                       WHERE g.user_id = p_grantor), true)
         -- At the grantor's level or below…
         AND qvm_new_apps.permission_rank_of(p_target) >= qvm_new_apps.permission_rank_of(p_grantor)
         -- …and inside something the grantor administers.
         AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_member_nodes(p_target) m
                      JOIN qvm_new_apps.permission_admin_nodes(p_grantor) a
                        ON a.kind = m.kind AND a.node_id = m.node_id)
       )
     );
$$;

------------------------------------------------------------------------------ resolution

-- What this user may do, page by page. User row, then company row, then role default; a role
-- with no defaults resolves to every page of its portal, exactly as it sees today.
-- `unrestricted` is true only when nothing anywhere has been decided for a role that has no
-- defaults either — the frontend then keeps its static behaviour for that role.
CREATE OR REPLACE FUNCTION qvm_new_apps.page_permissions_for(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_role int; v_type int; v_portal text; v_rank int;
  v_has_defaults boolean; v_decided boolean; v_can_delegate boolean;
  v_pages jsonb;
BEGIN
  SELECT user_role, user_type INTO v_role, v_type
    FROM qvm_new_apps.user_data WHERE user_id = p_user_id AND deleted_at IS NULL;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('unrestricted', false, 'is_admin', false, 'pages', '{}'::jsonb,
                              'can_delegate', false, 'portal', 'internal', 'rank', 9);
  END IF;
  v_portal := CASE WHEN v_type = 205 THEN 'vendor' ELSE 'internal' END;
  v_rank := qvm_new_apps.permission_rank_of(p_user_id);
  IF qvm_new_apps.is_qparts_admin(p_user_id) OR qvm_new_apps.is_company_admin(p_user_id) THEN
    RETURN jsonb_build_object('unrestricted', true, 'is_admin', true, 'pages', '{}'::jsonb,
                              'can_delegate', true, 'portal', v_portal, 'rank', v_rank);
  END IF;
  v_can_delegate := COALESCE((SELECT pr.can_delegate FROM qvm_new_apps.permission_roles pr WHERE pr.role_id = v_role), true)
                    AND EXISTS (SELECT 1 FROM qvm_new_apps.permission_admin_nodes(p_user_id));
  v_has_defaults := EXISTS (SELECT 1 FROM qvm_new_apps.permission_role_defaults d
                             WHERE d.role_id = v_role AND d.user_type IN (0, v_type));
  v_decided := EXISTS (SELECT 1 FROM qvm_new_apps.user_page_permissions u WHERE u.user_id = p_user_id)
            OR EXISTS (SELECT 1 FROM qvm_new_apps.company_role_permissions e
                        WHERE e.role_id = v_role
                          AND e.company_id IN (SELECT c.company_id FROM qvm_new_apps.permission_companies(p_user_id) c));

  SELECT COALESCE(jsonb_object_agg(x.nav_id, jsonb_build_object(
           'view', x.v, 'create', x.v AND x.c, 'update', x.v AND x.u, 'delete', x.v AND x.d,
           'source', x.source)), '{}'::jsonb)
    INTO v_pages
  FROM (
    SELECT pg.nav_id,
           CASE WHEN pg.is_always_on THEN true
                WHEN pg.nav_id IN ('permissions', 'vendor-permissions') THEN v_can_delegate
                ELSE COALESCE(u.can_view, c.can_view, d.can_view, NOT v_has_defaults) END AS v,
           COALESCE(u.can_create, c.can_create, d.can_create, NOT v_has_defaults) AS c,
           COALESCE(u.can_update, c.can_update, d.can_update, NOT v_has_defaults) AS u,
           COALESCE(u.can_delete, c.can_delete, d.can_delete, NOT v_has_defaults) AS d,
           CASE WHEN pg.is_always_on THEN 'always'
                WHEN pg.nav_id IN ('permissions', 'vendor-permissions') THEN 'computed'
                WHEN u.user_id IS NOT NULL THEN 'user'
                WHEN c.nav_id IS NOT NULL THEN 'company'
                WHEN d.nav_id IS NOT NULL THEN 'default'
                ELSE 'unrestricted' END AS source
      FROM qvm_new_apps.permission_pages pg
      LEFT JOIN qvm_new_apps.user_page_permissions u ON u.user_id = p_user_id AND u.nav_id = pg.nav_id
      LEFT JOIN (
        -- One row per company the user reaches: the union of what each allows.
        SELECT e.nav_id, bool_or(e.can_view) AS can_view, bool_or(e.can_create) AS can_create,
               bool_or(e.can_update) AS can_update, bool_or(e.can_delete) AS can_delete
          FROM qvm_new_apps.company_role_permissions e
         WHERE e.role_id = v_role
           AND e.company_id IN (SELECT c2.company_id FROM qvm_new_apps.permission_companies(p_user_id) c2)
         GROUP BY e.nav_id
      ) c ON c.nav_id = pg.nav_id
      LEFT JOIN (
        SELECT d.nav_id, bool_or(d.can_view) AS can_view, bool_or(d.can_create) AS can_create,
               bool_or(d.can_update) AS can_update, bool_or(d.can_delete) AS can_delete
          FROM qvm_new_apps.permission_role_defaults d
         WHERE d.role_id = v_role AND d.user_type IN (0, v_type)
         GROUP BY d.nav_id
      ) d ON d.nav_id = pg.nav_id
     WHERE pg.portal = v_portal
  ) x;

  RETURN jsonb_build_object(
    'unrestricted', (NOT v_has_defaults AND NOT v_decided),
    'is_admin', false, 'pages', v_pages,
    'can_delegate', v_can_delegate, 'portal', v_portal, 'rank', v_rank);
END $$;

-- Enforcement keeps its rule: only a DECIDED row (per user, then per company) is obeyed; an
-- undecided page behaves exactly as before this module existed.
CREATE OR REPLACE FUNCTION qvm_new_apps.has_page_permission(p_nav_id text, p_action text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_role int; v_row record;
BEGIN
  IF v_uid IS NULL THEN
    -- The service role, inside an edge function that has already identified the user.
    RETURN true;
  END IF;
  IF qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid) THEN RETURN true; END IF;
  SELECT can_view, can_create, can_update, can_delete INTO v_row
    FROM qvm_new_apps.user_page_permissions WHERE user_id = v_uid AND nav_id = p_nav_id;
  IF NOT FOUND THEN
    SELECT user_role INTO v_role FROM qvm_new_apps.user_data WHERE user_id = v_uid;
    SELECT bool_or(e.can_view) AS can_view, bool_or(e.can_create) AS can_create,
           bool_or(e.can_update) AS can_update, bool_or(e.can_delete) AS can_delete
      INTO v_row
      FROM qvm_new_apps.company_role_permissions e
     WHERE e.role_id = v_role AND e.nav_id = p_nav_id
       AND e.company_id IN (SELECT c.company_id FROM qvm_new_apps.permission_companies(v_uid) c);
    IF v_row.can_view IS NULL THEN RETURN true; END IF;   -- nobody decided: unchanged
  END IF;
  RETURN CASE p_action
    WHEN 'view' THEN v_row.can_view
    WHEN 'create' THEN v_row.can_create
    WHEN 'update' THEN v_row.can_update
    WHEN 'delete' THEN v_row.can_delete
    ELSE false END;
END $$;

-- The ceiling: what a grantor may hand out. Their own effective pages; everything for the two
-- admin roles, within what the platform lets a company give.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_ceiling(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_pages jsonb; v_all jsonb := jsonb_build_object('view', true, 'create', true, 'update', true, 'delete', true);
BEGIN
  IF qvm_new_apps.is_qparts_admin(p_user_id) THEN
    SELECT jsonb_object_agg(nav_id, v_all) INTO v_pages FROM qvm_new_apps.permission_pages
     WHERE nav_id NOT IN ('permissions', 'vendor-permissions');
    RETURN COALESCE(v_pages, '{}'::jsonb);
  END IF;
  IF qvm_new_apps.is_company_admin(p_user_id) THEN
    SELECT jsonb_object_agg(nav_id, v_all) INTO v_pages FROM qvm_new_apps.permission_pages
     WHERE is_company_page AND nav_id NOT IN ('permissions', 'vendor-permissions');
    RETURN COALESCE(v_pages, '{}'::jsonb);
  END IF;
  SELECT COALESCE(jsonb_object_agg(k, v - 'source'), '{}'::jsonb) INTO v_pages
    FROM jsonb_each(qvm_new_apps.page_permissions_for(p_user_id)->'pages') AS e(k, v)
   WHERE (v->>'view')::boolean AND k NOT IN ('permissions', 'vendor-permissions');
  RETURN v_pages;
END $$;

------------------------------------------------------------------------------ the delegation RPCs

-- Everyone the caller may manage, with where each of them stands.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_manageable_users()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_users jsonb; v_me jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  v_me := qvm_new_apps.page_permissions_for(v_uid);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
           'user_type', ud.user_type, 'user_role', ud.user_role, 'role_name', ld.list_data,
           'portal', CASE WHEN ud.user_type = 205 THEN 'vendor' ELSE 'internal' END,
           'rank', qvm_new_apps.permission_rank_of(ud.user_id),
           'is_admin', (qvm_new_apps.is_qparts_admin(ud.user_id) OR qvm_new_apps.is_company_admin(ud.user_id)),
           'granted_pages', (SELECT count(*) FROM qvm_new_apps.user_page_permissions u WHERE u.user_id = ud.user_id),
           'nodes', COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', m.kind, 'id', m.node_id,
                                       'label', qvm_new_apps.permission_node_label(m.kind, m.node_id)))
                               FROM qvm_new_apps.permission_member_nodes(ud.user_id) m), '[]'::jsonb)
         ) ORDER BY qvm_new_apps.permission_rank_of(ud.user_id), ud.user_name), '[]'::jsonb)
    INTO v_users
    FROM qvm_new_apps.user_data ud
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
   WHERE ud.deleted_at IS NULL
     AND qvm_new_apps.permission_can_manage(v_uid, ud.user_id);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'viewer', jsonb_build_object('user_id', v_uid, 'rank', v_me->'rank', 'portal', v_me->>'portal',
                                 'is_admin', v_me->'is_admin', 'can_delegate', v_me->'can_delegate'),
    'users', v_users));
END $$;

-- The roles this caller may give this target: same portal, not above the caller's level, not a
-- Qparts job title unless the caller is the Qparts Admin, and Company Admin only from an admin.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_assignable_roles_for(p_user_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'role_id', pr.role_id, 'role_name', ld.list_data, 'rank', pr.rank, 'sort_order', pr.sort_order)
           ORDER BY pr.rank, pr.sort_order, ld.list_data), '[]'::jsonb)
    FROM qvm_new_apps.permission_roles pr
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id
   WHERE pr.portal = qvm_new_apps.permission_portal_of(p_user_id)
     AND pr.rank >= qvm_new_apps.permission_rank_of(auth.uid())
     AND pr.role_id <> qvm_new_apps.role_id_by_name('Qparts Admin')
     AND (NOT pr.platform_only OR qvm_new_apps.is_qparts_admin(auth.uid()))
     AND (pr.role_id <> qvm_new_apps.company_admin_role_id()
          OR qvm_new_apps.is_qparts_admin(auth.uid()) OR qvm_new_apps.is_company_admin(auth.uid()));
$$;

-- One person's matrix, cut to the caller's ceiling.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_user_matrix(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_target jsonb; v_resolved jsonb; v_pages jsonb; v_portal text;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid);
  v_resolved := qvm_new_apps.page_permissions_for(p_user_id);
  v_portal := v_resolved->>'portal';
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
    -- The admin roles resolve to everything before any lookup; their matrix is read-only.
    'editable', NOT COALESCE((v_resolved->>'is_admin')::boolean, false),
    'pages', v_pages,
    'roles', qvm_new_apps.permission_assignable_roles_for(p_user_id),
    'viewer_rank', qvm_new_apps.permission_rank_of(v_uid)));
END $$;

-- Writes one person's cells. Every cell must sit inside the caller's ceiling, action by action.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_set_user(p_user_id uuid, p_cells jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_bad text; v_count int := 0; c jsonb; v_before jsonb; v_after jsonb; v_nav text; v_pg record;
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
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid);

  -- A cell outside the ceiling is refused before anything is written, and named.
  SELECT string_agg(DISTINCT x.nav_id, ', ') INTO v_bad
    FROM (
      SELECT btrim(e->>'nav_id') AS nav_id,
             COALESCE((e->>'view')::boolean, false) AS v, COALESCE((e->>'create')::boolean, false) AS c,
             COALESCE((e->>'update')::boolean, false) AS u, COALESCE((e->>'delete')::boolean, false) AS d
        FROM jsonb_array_elements(p_cells) e
    ) x
    LEFT JOIN qvm_new_apps.permission_pages pg ON pg.nav_id = x.nav_id
   WHERE pg.nav_id IS NULL
      OR pg.portal <> qvm_new_apps.permission_portal_of(p_user_id)
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
      -- An action on a page nobody may open is not a permission, it is a contradiction.
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

-- Forgets what was decided for one person, on the pages the caller holds, so the company layer
-- and the role defaults answer again.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_reset_user(p_user_id uuid, p_nav_ids text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_ceiling jsonb; v_count int;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  v_ceiling := qvm_new_apps.permission_ceiling(v_uid);
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

-- Gives a person a role, within what the caller may give.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_set_user_role(p_user_id uuid, p_role_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_old int;
BEGIN
  IF NOT qvm_new_apps.permission_can_manage(v_uid, p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to manage');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(qvm_new_apps.permission_assignable_roles_for(p_user_id)) r
                  WHERE (r->>'role_id')::int = p_role_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role is not yours to give');
  END IF;
  SELECT user_role INTO v_old FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_old IS DISTINCT FROM p_role_id THEN
    UPDATE qvm_new_apps.user_data SET user_role = p_role_id, updated_at = now() WHERE user_id = p_user_id;
    INSERT INTO qvm_new_apps.permission_grant_log (target_user_id, kind, before, after, granted_by)
    VALUES (p_user_id, 'role', to_jsonb(v_old), to_jsonb(p_role_id), v_uid);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('user_id', p_user_id, 'user_role', p_role_id));
END $$;

-- The catalogue, for drawing screens and for anyone asking what exists.
CREATE OR REPLACE FUNCTION qvm_new_apps.permission_catalog()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'pages', COALESCE((SELECT jsonb_agg(jsonb_build_object('nav_id', nav_id, 'label', label, 'portal', portal,
                        'sort_order', sort_order, 'is_company_page', is_company_page, 'is_always_on', is_always_on)
                        ORDER BY portal, sort_order) FROM qvm_new_apps.permission_pages), '[]'::jsonb),
    'roles', COALESCE((SELECT jsonb_agg(jsonb_build_object('role_id', pr.role_id, 'role_name', ld.list_data, 'portal', pr.portal,
                        'rank', pr.rank, 'platform_only', pr.platform_only, 'can_delegate', pr.can_delegate, 'is_assignable', pr.is_assignable)
                        ORDER BY pr.portal, pr.rank, pr.sort_order)
                        FROM qvm_new_apps.permission_roles pr JOIN qvm_new_apps.list_data ld ON ld.list_data_id = pr.role_id), '[]'::jsonb)));
$$;

------------------------------------------------------------------------------ the public face

CREATE OR REPLACE FUNCTION public.my_page_permissions() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT jsonb_build_object('success', true, 'data', qvm_new_apps.page_permissions_for(auth.uid()));
$$;
CREATE OR REPLACE FUNCTION public.permission_manageable_users() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_manageable_users() $$;
CREATE OR REPLACE FUNCTION public.permission_user_matrix(p_user_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_user_matrix(p_user_id) $$;
CREATE OR REPLACE FUNCTION public.permission_set_user(p_user_id uuid, p_cells jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_set_user(p_user_id, p_cells) $$;
CREATE OR REPLACE FUNCTION public.permission_reset_user(p_user_id uuid, p_nav_ids text[] DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_reset_user(p_user_id, p_nav_ids) $$;
CREATE OR REPLACE FUNCTION public.permission_set_user_role(p_user_id uuid, p_role_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_set_user_role(p_user_id, p_role_id) $$;
CREATE OR REPLACE FUNCTION public.permission_catalog() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.permission_catalog() $$;
