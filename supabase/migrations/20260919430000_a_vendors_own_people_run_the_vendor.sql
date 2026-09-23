-- A vendor's own people run the vendor; the tree opens for every level and says what each may edit.
--
-- can_admin_vendor now includes the vendor's admin (is_vendor_admin_for), and a branch's own users
-- run that branch. The vendor users list and branch assignment gate on the same helper, so a
-- Company Admin of a buying company manages the vendor's users from the tree as well. The tree
-- is scoped per level and flags every vendor and branch with can_edit.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_vendor(p_vendor_id integer)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $function$
  SELECT qvm_new_apps.is_qparts_admin(auth.uid())
      OR (qvm_new_apps.is_company_admin(auth.uid())
          AND EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies vc
                       WHERE vc.vendor_id = p_vendor_id AND qvm_new_apps.can_admin_company(vc.company_id)))
      OR qvm_new_apps.is_vendor_admin_for(p_vendor_id);
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.can_admin_vendor(integer) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.can_admin_vendor_branch(p_vendor_branch_id bigint)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $function$
  SELECT qvm_new_apps.can_admin_vendor((SELECT b.vendor_id FROM qvm_new_apps.vendor_branches b WHERE b.vendor_branch_id = p_vendor_branch_id))
      OR EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
                  JOIN qvm_new_apps.user_data ud ON ud.user_id = vbu.user_id
                 WHERE vbu.vendor_branch_id = p_vendor_branch_id AND vbu.user_id = auth.uid() AND ud.deleted_at IS NULL);
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.can_admin_vendor_branch(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_users(p_vendor_id integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.can_admin_vendor(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'user_id', u.user_id, 'user_name', u.user_name, 'email', u.email,
           'user_role', ur.list_data, 'user_role_id', u.user_role,
           'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object('vendor_branch_id', vb.vendor_branch_id, 'branch_name', vb.branch_name, 'city', vb.city))
                                   FROM qvm_new_apps.vendor_branch_users vbu
                                   JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
                                  WHERE vbu.user_id = u.user_id), '[]'::jsonb)
         ) ORDER BY u.user_name), '[]'::jsonb)
    INTO v_result
  FROM qvm_new_apps.user_data u
  LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
  WHERE u.user_vendor = p_vendor_id AND u.deleted_at IS NULL;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.assign_vendor_user_branches(p_user_id uuid, p_vendor_branch_ids bigint[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_vendor_id integer; v_bad_branch_count integer;
BEGIN
  SELECT user_vendor INTO v_vendor_id FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_vendor_id IS NULL THEN RAISE EXCEPTION 'Vendor user not found'; END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.can_admin_vendor(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT count(*) INTO v_bad_branch_count
    FROM unnest(COALESCE(p_vendor_branch_ids, ARRAY[]::bigint[])) bid
   WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branches vb WHERE vb.vendor_branch_id = bid AND vb.vendor_id = v_vendor_id);
  IF v_bad_branch_count > 0 THEN RAISE EXCEPTION 'One or more branches do not belong to this vendor'; END IF;
  DELETE FROM qvm_new_apps.vendor_branch_users WHERE user_id = p_user_id;
  INSERT INTO qvm_new_apps.vendor_branch_users (user_id, vendor_branch_id)
  SELECT p_user_id, bid FROM unnest(COALESCE(p_vendor_branch_ids, ARRAY[]::bigint[])) bid;
  RETURN jsonb_build_object('status', true);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_vendor_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  -- Every level opens the tree and sees what it runs: Qparts everything, a Company Admin the
  -- vendors of their companies, a Vendor Admin their vendor, a vendor user their branches.
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.user_type = 205
                        AND ud.user_vendor IS NOT NULL AND ud.deleted_at IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH vendor_json AS (
    SELECT v.vendor_id,
           jsonb_build_object(
             'vendor_id', v.vendor_id,
             'display_name', COALESCE(vv.name, v.vendor_name),
             'vendor_code', v.vendor_code,
             'vendor_type', v.vendor_type,
             'email', v.email,
             'can_edit', qvm_new_apps.can_admin_vendor(v.vendor_id),
             -- Identity and terms, as the vendor form collects them.
             'vendor_type_id', v.vendor_type_id,
             'tax_number', v.tax_number,
             'cr_kind', v.cr_kind,
             'cr_number', v.commercial_registeration_number,
             'receives_quotations', COALESCE(v.receives_quotations, true),
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'vendors' AND f.module_id = v.vendor_id), '[]'::jsonb),
             'city', vc.name,
             'city_id', v.city_id,
             'branch_count', vv.branch_count,
             'company_ids', COALESCE((SELECT jsonb_agg(x.company_id ORDER BY x.company_id)
                                        FROM qvm_new_apps.vendor_companies x
                                       WHERE x.vendor_id = v.vendor_id), '[]'::jsonb),
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.vendors_descriptions d
                                 WHERE d.vendor_id = v.vendor_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'vendor_branch_id', b.vendor_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'can_edit', qvm_new_apps.can_admin_vendor_branch(b.vendor_branch_id),
                        'branch_code', vb.branch_code,
                        'brand_ids', COALESCE(vb.brands, '[]'::jsonb),
                        'part_category_ids', COALESCE(vb.categories, '[]'::jsonb),
                        -- The bank rows in the shape the shared form uses; the vendor portal's keys stay on the row.
                        'banks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                     'bank_name', COALESCE(x->>'bank_name', ''),
                                     'account_name_ar', COALESCE(x->>'bank_account_name', ''),
                                     'account_name_en', COALESCE(x->>'bank_account_name_en', ''),
                                     'iban', COALESCE(x->>'bank_iban', '')))
                                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(vb.banks) = 'array' THEN vb.banks ELSE '[]'::jsonb END) x), '[]'::jsonb),
                        'account_type', vb.account_type,
                        'credit_limit', vb.credit_limit,
                        'credit_term_days', vb.credit_term_days,
                        'hours_mode', vb.hours_mode,
                        'working_hours', COALESCE(vb.working_hours, '[]'::jsonb),
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.vendor_branches_descriptions bd
                                            WHERE bd.vendor_branch_id = b.vendor_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_vendor_branches b
                 JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = b.vendor_branch_id
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.vendor_id = v.vendor_id
                  -- A vendor user sees the branches they are assigned to; the vendor's admins see them all.
                  AND (qvm_new_apps.can_admin_vendor(v.vendor_id)
                       OR EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
                                   WHERE vbu.user_id = v_uid AND vbu.vendor_branch_id = b.vendor_branch_id))), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.vendors v
    JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
    LEFT JOIN qvm_new_apps.v_cities vc ON vc.city_id = v.city_id
   WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
      OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.user_vendor = v.vendor_id AND ud.deleted_at IS NULL)
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    -- A vendor nobody has linked belongs to no company, so it is nobody's but Qparts'.
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                  FROM vendor_json vj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies x
                                    WHERE x.vendor_id = vj.vendor_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY s.vendor_count DESC, s.created_at DESC NULLS LAST, co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'created_at', c.created_at,
          'vendor_count', (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id),
          'vendors', COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                                 FROM vendor_json vj
                                 JOIN qvm_new_apps.vendor_companies x
                                   ON x.vendor_id = vj.vendor_id AND x.company_id = c.company_id), '[]'::jsonb)
        ) AS co,
        c.created_at,
        (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id) AS vendor_count
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
          -- Or a company the caller's vendor sells to: read-only at the company level.
          OR EXISTS (SELECT 1 FROM vendor_json vj JOIN qvm_new_apps.vendor_companies x ON x.vendor_id = vj.vendor_id
                      WHERE x.company_id = c.company_id)
      ) s), '[]'::jsonb),
    'viewer', jsonb_build_object('level',
      CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN 'qparts'
           WHEN qvm_new_apps.is_company_admin(v_uid) THEN 'company'
           WHEN EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud JOIN qvm_new_apps.list_data r ON r.list_data_id = ud.user_role
                         WHERE ud.user_id = v_uid AND r.list_data = 'Vendor Admin') THEN 'vendor'
           ELSE 'branch' END)
  )) INTO v_res;

  RETURN v_res;
END $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 47 $$;
