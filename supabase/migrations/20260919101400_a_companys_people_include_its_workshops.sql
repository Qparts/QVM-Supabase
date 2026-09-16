-- A company's people are not only the ones attached to the company.
--
-- admin_list_company_users read user_companies and stopped: the people the Company Admin attached
-- to the company directly. But most of a company's people are not attached that way — they are
-- attached to one of its workshops, or pinned to a branch of one of those workshops, and the
-- supervisor ladder, the user list and the role screen all need to see them. So the list is now the
-- union of three ways of belonging, each row saying which:
--
--   company   — user_companies, as before
--   workshop  — user_workshops on a workshop the company owns or is served by
--   branch    — user_data.user_branch on a branch of one of those workshops
--
-- A person can belong more than one way; they appear once, under the most direct of them, with the
-- workshop and branch they sit at named so a picker can group them.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_list_company_users(p_company_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', COALESCE((
    WITH ws AS (
      -- The company's workshops: the ones it owns, and the ones that serve it.
      SELECT w.workshop_id FROM qvm_new_apps.client_workshops w WHERE w.company_id = p_company_id
      UNION
      SELECT wc.workshop_id FROM qvm_new_apps.workshop_companies wc WHERE wc.company_id = p_company_id
    ),
    belonging AS (
      SELECT uc.user_id, 1 AS rank, 'company'::text AS source, NULL::bigint AS workshop_id, NULL::integer AS branch_id
        FROM qvm_new_apps.user_companies uc WHERE uc.company_id = p_company_id
      UNION ALL
      SELECT uw.user_id, 2, 'workshop', uw.workshop_id, NULL
        FROM qvm_new_apps.user_workshops uw JOIN ws ON ws.workshop_id = uw.workshop_id
      UNION ALL
      SELECT ud.user_id, 3, 'branch', cb.workshop_id, cb.customer_id
        FROM qvm_new_apps.user_data ud
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = ud.user_branch
        JOIN ws ON ws.workshop_id = cb.workshop_id
    ),
    one_per_user AS (
      SELECT DISTINCT ON (b.user_id) b.*
        FROM belonging b
       ORDER BY b.user_id, b.rank
    )
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email,
             'user_type', ud.user_type, 'user_role', ud.user_role, 'role_name', ld.list_data,
             'branch_count', COALESCE(array_length(qvm_new_apps.effective_branch_ids(ud.user_id), 1), 0),
             'source', o.source,
             'workshop_id', o.workshop_id,
             'workshop_name', vw.name,
             'branch_id', o.branch_id,
             'branch_name', vb.name)
           ORDER BY o.rank, vw.name NULLS FIRST, vb.name NULLS FIRST, ud.user_name)
      FROM one_per_user o
      JOIN qvm_new_apps.user_data ud ON ud.user_id = o.user_id
      LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ud.user_role
      LEFT JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = o.workshop_id
      LEFT JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = o.branch_id
     WHERE ud.deleted_at IS NULL
  ), '[]'::jsonb));
END $function$;
