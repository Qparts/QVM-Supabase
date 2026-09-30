-- A company admin says who may change the selling price.
--
-- The flag «can update selling price» lived on the Internal Users page, which is hidden now. The
-- Companies & Workshops page lists it per company user and sets it, for the people the caller
-- administers — the same gate admin_set_user_role applies.

set search_path to qvm_new_apps, public;

create or replace function qvm_new_apps.admin_set_user_selling_price(p_user_id uuid, p_allowed boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_uid uuid := auth.uid(); v_type int; v_ok boolean;
begin
  select user_type into v_type from qvm_new_apps.user_data where user_id = p_user_id;
  if v_type is null then
    return jsonb_build_object('success', false, 'error', 'User not found');
  end if;
  if qvm_new_apps.is_qparts_admin(v_uid) then
    v_ok := true;
  else
    v_ok := qvm_new_apps.is_company_admin(v_uid)
        and exists (select 1 from qvm_new_apps.permission_companies(p_user_id))
        and not exists (
              select 1 from qvm_new_apps.permission_companies(p_user_id) c
               where not qvm_new_apps.can_admin_company(c.company_id));
  end if;
  if not v_ok then
    return jsonb_build_object('success', false, 'error', 'Access denied: this user is not yours to administer');
  end if;

  update qvm_new_apps.user_data
     set can_update_selling_price = coalesce(p_allowed, false), updated_at = now()
   where user_id = p_user_id;

  return jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user_id', p_user_id, 'can_update_selling_price', coalesce(p_allowed, false)));
end $function$;

create or replace function public.admin_set_user_selling_price(p_user_id uuid, p_allowed boolean)
 returns jsonb
 language sql
 security definer
as $function$
  select qvm_new_apps.admin_set_user_selling_price(p_user_id, p_allowed);
$function$;

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
             -- Whether this person may change a selling price after a line is priced; set from this page now.
             'can_update_selling_price', COALESCE(ud.can_update_selling_price, false),
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
