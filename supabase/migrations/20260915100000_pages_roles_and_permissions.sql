-- Roles and permissions, per company, over the pages in the sidebar.
--
-- Access has been decided in one TypeScript file: a role maps to a list of nav ids, the same list
-- everywhere, and the only way to change it is a deploy. That is the wrong shape for what companies
-- actually want — one lets its service advisors raise requests but never cancel them, another lets
-- its branch managers do both, and neither is a platform-wide truth.
--
-- Permission attaches to (company, role, page) with four flags: view, create, update, delete. The
-- roles are the ones already in list 16 rather than a second role system beside it, because a user
-- already has exactly one role and two answers to "what is this person" is one too many.
--
-- Nothing changes on the day this lands. A company with no rows of its own resolves to the defaults
-- seeded below, which are transcribed from the menus in config/navAccess.ts as they stand. Existing
-- pages get create, update and delete as well as view — a permissions system whose first act is to
-- take away what people were doing yesterday would be read as a fault, correctly.
--
-- Two roles are never consulted: Qparts Admin runs the platform, and Company Admin runs the
-- company. Both resolve to everything before any lookup happens, so a Company Admin cannot lock
-- themselves out of the screen they use to grant permissions.

------------------------------------------------------------------------------ the pages

CREATE TABLE IF NOT EXISTS qvm_new_apps.nav_pages (
  nav_id     text PRIMARY KEY,
  label      text NOT NULL,
  sort_order integer NOT NULL DEFAULT 100,
  -- A page a company can be given. Languages, Internal Users and the platform logs are not: they
  -- belong to Qparts, and offering them in a company's matrix would be offering a decision that is
  -- not theirs to make.
  is_company_page boolean NOT NULL DEFAULT true,
  -- Profile is everyone's. It is listed so the matrix is complete, and pinned so it cannot be
  -- switched off by accident.
  is_always_on boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO qvm_new_apps.nav_pages (nav_id, label, sort_order, is_always_on) VALUES
  ('overview', 'Overview', 10, false),
  ('management-overview', 'Management Overview', 20, false),
  ('internal-dashboard', 'Internal Dashboard', 30, false),
  ('new-rfq', 'New RFQ', 40, false),
  ('rfqs', 'RFQs', 50, false),
  ('orders', 'Orders', 60, false),
  ('delivered', 'Delivered Orders', 70, false),
  ('extract-pn', 'Extract Part Number', 80, false),
  ('purchase-invoices', 'Purchase Orders', 90, false),
  ('returns-exchanges', 'Returns & Exchanges', 100, false),
  ('shipment-dashboard', 'Shipments', 110, false),
  ('parts-pricing-report', 'Parts Pricing', 120, false),
  ('performance-reports', 'Performance Reports', 130, false),
  ('invoices', 'Invoices', 140, false),
  ('statement', 'Statement', 150, false),
  ('client-tree', 'Companies & Workshops', 160, false),
  ('account-managers', 'Account Managers', 170, false),
  ('vendors', 'Vendors', 180, false),
  ('insurance-companies', 'Insurance Companies', 190, false),
  ('send-notification', 'Send Notification', 200, false),
  ('notification-rules', 'Notification Rules', 210, false),
  ('notification-settings', 'Notification Settings', 220, false),
  ('profile', 'Profile', 999, true)
ON CONFLICT (nav_id) DO UPDATE SET label = EXCLUDED.label, sort_order = EXCLUDED.sort_order;

------------------------------------------------------------------------------ the roles

CREATE TABLE IF NOT EXISTS qvm_new_apps.permission_roles (
  role_id       integer PRIMARY KEY REFERENCES qvm_new_apps.list_data(list_data_id),
  sort_order    integer NOT NULL DEFAULT 100,
  -- Whether a company may assign this role and therefore set permissions for it. Vendors are not
  -- company users today; when they are, this is a row to update rather than code to change.
  is_assignable boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Matched by name, not by number: role ids are minted per environment.
INSERT INTO qvm_new_apps.permission_roles (role_id, sort_order)
SELECT ld.list_data_id, v.so
FROM (VALUES

  ('Client Admin', 10),
  ('Service Advisor', 20),
  ('Branch Manager', 30),
  ('Internal Branch User', 40)

) AS v(name, so)
JOIN qvm_new_apps.list_data ld ON ld.list_id = 16 AND lower(btrim(ld.list_data)) = lower(v.name)
ON CONFLICT (role_id) DO UPDATE SET sort_order = EXCLUDED.sort_order;

------------------------------------------------------------------------------ what a role gets by default

CREATE TABLE IF NOT EXISTS qvm_new_apps.nav_page_role_defaults (
  role_id    integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  nav_id     text    NOT NULL REFERENCES qvm_new_apps.nav_pages(nav_id) ON DELETE CASCADE,
  can_view   boolean NOT NULL DEFAULT false,
  can_create boolean NOT NULL DEFAULT false,
  can_update boolean NOT NULL DEFAULT false,
  can_delete boolean NOT NULL DEFAULT false,
  PRIMARY KEY (role_id, nav_id)
);

INSERT INTO qvm_new_apps.nav_page_role_defaults (role_id, nav_id, can_view, can_create, can_update, can_delete)
SELECT ld.list_data_id, v.nav_id, true, true, true, true
FROM (VALUES

  ('Client Admin', 'overview'),
  ('Client Admin', 'purchase-invoices'),
  ('Client Admin', 'new-rfq'),
  ('Client Admin', 'rfqs'),
  ('Client Admin', 'orders'),
  ('Client Admin', 'shipment-dashboard'),
  ('Client Admin', 'invoices'),
  ('Client Admin', 'statement'),
  ('Client Admin', 'profile'),
  ('Service Advisor', 'overview'),
  ('Service Advisor', 'purchase-invoices'),
  ('Service Advisor', 'new-rfq'),
  ('Service Advisor', 'rfqs'),
  ('Service Advisor', 'orders'),
  ('Service Advisor', 'shipment-dashboard'),
  ('Service Advisor', 'invoices'),
  ('Service Advisor', 'statement'),
  ('Service Advisor', 'profile'),
  ('Branch Manager', 'overview'),
  ('Branch Manager', 'purchase-invoices'),
  ('Branch Manager', 'new-rfq'),
  ('Branch Manager', 'rfqs'),
  ('Branch Manager', 'orders'),
  ('Branch Manager', 'shipment-dashboard'),
  ('Branch Manager', 'invoices'),
  ('Branch Manager', 'statement'),
  ('Branch Manager', 'profile'),
  ('Internal Branch User', 'overview'),
  ('Internal Branch User', 'management-overview'),
  ('Internal Branch User', 'internal-dashboard'),
  ('Internal Branch User', 'extract-pn'),
  ('Internal Branch User', 'purchase-invoices'),
  ('Internal Branch User', 'returns-exchanges'),
  ('Internal Branch User', 'parts-pricing-report'),
  ('Internal Branch User', 'invoices'),
  ('Internal Branch User', 'statement'),
  ('Internal Branch User', 'vendors'),
  ('Internal Branch User', 'insurance-companies'),
  ('Internal Branch User', 'send-notification'),
  ('Internal Branch User', 'notification-rules'),
  ('Internal Branch User', 'notification-settings'),
  ('Internal Branch User', 'profile')

) AS v(role_name, nav_id)
JOIN qvm_new_apps.list_data ld ON ld.list_id = 16 AND lower(btrim(ld.list_data)) = lower(v.role_name)
ON CONFLICT (role_id, nav_id) DO NOTHING;

------------------------------------------------------------------------------ what a company decided

CREATE TABLE IF NOT EXISTS qvm_new_apps.company_role_permissions (
  company_id integer NOT NULL REFERENCES qvm_new_apps.client_companies(company_id) ON DELETE CASCADE,
  role_id    integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  nav_id     text    NOT NULL REFERENCES qvm_new_apps.nav_pages(nav_id) ON DELETE CASCADE,
  can_view   boolean NOT NULL DEFAULT false,
  can_create boolean NOT NULL DEFAULT false,
  can_update boolean NOT NULL DEFAULT false,
  can_delete boolean NOT NULL DEFAULT false,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, role_id, nav_id)
);
CREATE INDEX IF NOT EXISTS idx_company_role_permissions_lookup
  ON qvm_new_apps.company_role_permissions (company_id, role_id);

GRANT ALL ON qvm_new_apps.nav_pages, qvm_new_apps.permission_roles,
             qvm_new_apps.nav_page_role_defaults, qvm_new_apps.company_role_permissions TO service_role;
