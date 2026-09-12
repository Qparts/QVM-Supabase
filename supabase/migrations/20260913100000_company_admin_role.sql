-- Company Admin: everything for one company, nothing for anyone else's.
--
-- The gap this fills: a company's own people could see their data but could change nothing about
-- it. Adding a workshop, adding a branch, naming who covers it — all of that sat behind Qparts
-- Admin, so the very first RFQ on a new branch failed with "No account manager allocation found"
-- and the only person who could fix it worked at Qparts.
--
-- So the permission stops being a single global flag and becomes a question about a company:
--
--   is_qparts_admin()              — everything, everywhere, as before
--   can_admin_company(company_id)  — that plus a Company Admin, for the companies they are on
--
-- A Company Admin is an internal account (185) scoped through user_companies, exactly like the
-- Internal Branch User, and the difference between them is only what they may CHANGE.

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 16, 'Company Admin'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 16 AND list_data = 'Company Admin');

-- Resolved by name rather than hardcoded: this row's id is whatever the identity column handed out.
CREATE OR REPLACE FUNCTION qvm_new_apps.company_admin_role_id()
RETURNS integer LANGUAGE sql STABLE SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT list_data_id FROM qvm_new_apps.list_data
   WHERE list_id = 16 AND list_data = 'Company Admin' LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.is_company_admin(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud
                  WHERE ud.user_id = p_user_id
                    AND ud.user_role = qvm_new_apps.company_admin_role_id()
                    AND ud.deleted_at IS NULL);
$$;

-- May the caller administer this company? NULL company means "anything at all", which only a
-- Qparts Admin can answer yes to — a Company Admin always acts on a named company.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_company(p_company_id integer DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR (p_company_id IS NOT NULL
          AND qvm_new_apps.is_company_admin(auth.uid())
          AND EXISTS (SELECT 1 FROM qvm_new_apps.user_companies uc
                       WHERE uc.user_id = auth.uid() AND uc.company_id = p_company_id));
$$;

-- The same question about a workshop, which belongs to one or more companies: administering any of
-- them is enough, since the workshop is shared between them.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_workshop(p_workshop_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                  WHERE wc.workshop_id = p_workshop_id
                    AND qvm_new_apps.can_admin_company(wc.company_id));
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_branch(p_customer_id integer)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb
                  WHERE cb.customer_id = p_customer_id
                    AND qvm_new_apps.can_admin_workshop(cb.workshop_id));
$$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.company_admin_role_id() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.is_company_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.can_admin_company(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.can_admin_workshop(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.can_admin_branch(integer) TO authenticated;

-- What the app needs to know about the signed-in account to draw itself.
CREATE OR REPLACE FUNCTION public.my_admin_context() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'is_qparts_admin', qvm_new_apps.is_qparts_admin(auth.uid()),
    'is_company_admin', qvm_new_apps.is_company_admin(auth.uid()),
    'company_admin_role_id', qvm_new_apps.company_admin_role_id(),
    'company_ids', COALESCE((SELECT jsonb_agg(uc.company_id ORDER BY uc.company_id)
                               FROM qvm_new_apps.user_companies uc WHERE uc.user_id = auth.uid()),
                            '[]'::jsonb)));
$$;
GRANT EXECUTE ON FUNCTION public.my_admin_context() TO authenticated;
