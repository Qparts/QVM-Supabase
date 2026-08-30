-- Deleting an internal user's login previously tried to hard-delete their qvm_new_apps.user_data
-- row, which fails with a foreign key violation the moment that user has ANY historical activity
-- (status_logs.status_changed_by, pricing_logs.created_by, cost_logs.created_by,
-- quotations.account_manager/service_advisor, purchase_orders.uploaded_by, notes.user_id, etc. all
-- reference user_data(user_id) with NO ACTION). Confirmed live: deleting a real test sub-user failed
-- with "violates foreign key constraint status_logs_status_changed_by_fkey".
--
-- user_data.user_id has no FK to auth.users at all, so deleting only the auth.users row already
-- fully revokes login/access without touching any audit trail. This adds a deleted_at marker so the
-- Internal Users list can hide revoked accounts while their historical rows (and every audit FK
-- pointing at them) stay intact.
ALTER TABLE qvm_new_apps.user_data
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_internal_users()
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

  IF qvm_new_apps.get_internal_branch_scope(auth.uid()) IS NOT NULL THEN
    RAISE EXCEPTION 'Not authorized: Qparts Admin only';
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
  WHERE ud.user_company = v_company_id AND ud.user_type = 185 AND ud.deleted_at IS NULL
  GROUP BY ud.user_id, ud.user_name, ud.email, ud.user_role, ur.list_data, ud.can_update_selling_price
  ORDER BY ud.user_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_internal_users() TO authenticated;
