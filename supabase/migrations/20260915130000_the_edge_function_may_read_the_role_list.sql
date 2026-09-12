-- The edge function can read the list of roles it is asked to validate against.
--
--   {"status":"fail","message":"Could not read the roles: permission denied for function
--     admin_assignable_roles"}
--
-- Two faults, in a row, both mine. The function was granted to `authenticated` and revoked from
-- everyone else, and the service role is neither — so the call was refused before it ran. Fixing
-- only that would have moved the failure rather than removed it: the body asks
-- is_qparts_admin(auth.uid()) OR is_company_admin(auth.uid()), and auth.uid() is NULL for the
-- service role, so it would have returned an empty list and the edge function would have rejected
-- every role as unassignable.
--
-- is_qparts_admin_or_service() is the pattern already used for this, by admin_set_user_scope, which
-- the same edge function calls two lines later. It reads the role claim rather than the user, so a
-- service-role connection passes and an anonymous one does not.
--
-- Letting the service role read this list gives nothing away. The caller has already been
-- identified and checked by the edge function itself — Qparts Admin, or a Company Admin acting on
-- their own company — and what comes back is the names of four roles.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_assignable_roles()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin_or_service()
          OR qvm_new_apps.is_company_admin(v_uid)) THEN
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

GRANT EXECUTE ON FUNCTION public.admin_assignable_roles() TO service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_assignable_roles() TO service_role;
