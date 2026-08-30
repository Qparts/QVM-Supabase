-- Internal Users page: a per-user "Can update selling price" flag for internal branch users.
-- Qparts Admin (user_role = 172) accounts can already edit the selling price in any case via the
-- pricing modal's existing role check there — this flag extends that same "in any case" bypass to
-- specific branch-scoped internal users, opted in individually at creation/edit time.
ALTER TABLE qvm_new_apps.user_data
  ADD COLUMN IF NOT EXISTS can_update_selling_price boolean NOT NULL DEFAULT false;

-- Surface the flag in the JWT's user_data claim (consumed by hooks/useAuth.tsx -> PricingPage.tsx),
-- same pattern already used for is_vendor_admin.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_user_data(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  result jsonb;
  v_vendor_admin_role_id integer;
BEGIN
  SELECT ld.list_data_id INTO v_vendor_admin_role_id
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
  WHERE l.list_name = 'user_role' AND ld.list_data = 'Vendor Admin';

  SELECT jsonb_build_object(
           'user_id', u.user_id,
           'email', u.email,
           'user_name', u.user_name,
           'user_role', ur.list_data,
           'user_role_id', u.user_role,
           'user_type', ut.list_data,
           'user_type_id', u.user_type,
           'user_company', uc.list_data,
           'user_company_id', u.user_company,
           'user_branch', cb.branch_name,
           'user_branch_id', u.user_branch,
           'user_vendor_id', u.user_vendor,
           'is_vendor_admin', (u.user_role IS NOT NULL AND u.user_role = v_vendor_admin_role_id),
           'can_update_selling_price', COALESCE(u.can_update_selling_price, false),
           'preferred_branch_id', pv.preferred_branch_id,
           'vendor_branches', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'vendor_branch_id', vb.vendor_branch_id,
                      'branch_name', vb.branch_name,
                      'city', vb.city
                    ) ORDER BY vb.city, vb.branch_name)
             FROM qvm_new_apps.vendor_branch_users vbu
             JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
             WHERE vbu.user_id = u.user_id
           ), '[]'::jsonb)
         )
  INTO result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON u.user_role = ur.list_data_id
  LEFT JOIN qvm_new_apps.list_data ut ON u.user_type = ut.list_data_id
  LEFT JOIN qvm_new_apps.list_data uc ON u.user_company = uc.list_data_id
  LEFT JOIN qvm_new_apps.client_branches cb ON u.user_branch = cb.customer_id
  LEFT JOIN qvm_new_apps.vendors pv ON pv.vendor_id = u.user_vendor
  WHERE u.user_id = p_user_id;

  RETURN result;
END;
$function$;

-- Surface the flag on the Internal Users management list so admins can see who has it.
DROP FUNCTION IF EXISTS qvm_new_apps.list_internal_users();

CREATE FUNCTION qvm_new_apps.list_internal_users()
 RETURNS TABLE(
   user_id uuid,
   user_name text,
   email text,
   user_role_id integer,
   user_role_name text,
   branch_ids integer[],
   branch_names text[],
   can_update_selling_price boolean
 )
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT ud.user_company INTO v_company_id FROM qvm_new_apps.user_data ud WHERE ud.user_id = auth.uid();
  IF v_company_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    ud.user_id,
    ud.user_name,
    ud.email,
    ud.user_role,
    ur.list_data AS user_role_name,
    COALESCE(array_agg(iub.branch_id) FILTER (WHERE iub.branch_id IS NOT NULL), ARRAY[]::integer[]) AS branch_ids,
    COALESCE(array_agg(cb.branch_name) FILTER (WHERE cb.branch_name IS NOT NULL), ARRAY[]::text[]) AS branch_names,
    COALESCE(ud.can_update_selling_price, false) AS can_update_selling_price
  FROM qvm_new_apps.user_data ud
  LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = ud.user_role
  LEFT JOIN qvm_new_apps.internal_user_branches iub ON iub.user_id = ud.user_id
  LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = iub.branch_id
  WHERE ud.user_company = v_company_id AND ud.user_type = 185
  GROUP BY ud.user_id, ud.user_name, ud.email, ud.user_role, ur.list_data, ud.can_update_selling_price
  ORDER BY ud.user_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_internal_users() TO authenticated;
