-- The tree carries each workshop's code.
--
-- A code nobody can see is a code nobody can give out. It rides along with the workshop rather than
-- needing a call of its own, since every screen that would show it already has the tree.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH workshop_json AS (
    SELECT w.workshop_id, w.company_id,
           jsonb_build_object(
             'workshop_id', w.workshop_id,
             'company_id', w.company_id,
             -- What a company types to link itself to this workshop. Shown on the workshop so it
             -- can be passed on; there is no way to search by it.
             'workshop_code', w.workshop_code,
             'company_ids', COALESCE((SELECT jsonb_agg(wc.company_id ORDER BY wc.company_id)
                                        FROM qvm_new_apps.workshop_companies wc
                                       WHERE wc.workshop_id = w.workshop_id), '[]'::jsonb),
             'display_name', vw.name,
             'city', w.city,
             'city_id', w.city_id,
             'is_active', w.is_active,
             'branch_count', vw.branch_count,
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.client_workshops_descriptions d
                                 WHERE d.workshop_id = w.workshop_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'customer_id', b.customer_id,
                        'display_name', vb.name,
                        'city', b.city,
                        'city_id', b.city_id,
                        'is_bulk_client', b.is_bulk_client,
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                            ORDER BY d.language_id)
                                             FROM qvm_new_apps.client_branches_descriptions d
                                            WHERE d.customer_id = b.customer_id), '[]'::jsonb),
                        'manager_count', (SELECT count(*) FROM qvm_new_apps.user_branches ub
                                           WHERE ub.client_branch_id = b.customer_id AND ub.is_manager),
                        -- Shown per branch because that is where it fails: an order is raised on a
                        -- branch, and this is the list of reasons it would be refused.
                        'readiness', qvm_new_apps.branch_quotation_readiness(b.customer_id))
                      ORDER BY vb.name)
                 FROM qvm_new_apps.client_branches b
                 JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = b.customer_id
                WHERE b.workshop_id = w.workshop_id), '[]'::jsonb),
             'user_count', (SELECT count(*) FROM qvm_new_apps.user_workshops uw WHERE uw.workshop_id = w.workshop_id)
           ) AS ws
    FROM qvm_new_apps.client_workshops w
    JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
  )
  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                               FROM (SELECT language_id, code, english_name, native_name, direction,
                                            is_active, is_default, sort_order
                                       FROM qvm_new_apps.languages WHERE is_active) l), '[]'::jsonb),
      -- Workshops with no company belong to nobody's company, so only Qparts sees the pile.
      'unassigned_workshops', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
        COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                    FROM workshop_json wj
                   WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                                      WHERE wc.workshop_id = wj.workshop_id)), '[]'::jsonb)
        ELSE '[]'::jsonb END,
      'companies', COALESCE((
        SELECT jsonb_agg(co ORDER BY co->>'display_name')
        FROM (
          SELECT jsonb_build_object(
            'company_id', c.company_id,
            'display_name', vc.name,
            'cr_number', c.cr_number,
            'vat_number', c.vat_number,
            'is_active', c.is_active,
            'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                ORDER BY d.language_id)
                                 FROM qvm_new_apps.client_companies_descriptions d
                                WHERE d.company_id = c.company_id), '[]'::jsonb),
            'workshops', COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                                     FROM workshop_json wj
                                     JOIN qvm_new_apps.workshop_companies wc
                                       ON wc.workshop_id = wj.workshop_id
                                    WHERE wc.company_id = c.company_id), '[]'::jsonb)
          ) AS co
          FROM qvm_new_apps.client_companies c
          JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = c.company_id
          -- A Company Admin gets their own companies and no others; can_admin_company answers
          -- true for everything when the caller is a Qparts Admin, so this line is a no-op there.
         WHERE qvm_new_apps.can_admin_company(c.company_id)
        ) s), '[]'::jsonb)
    ))
  INTO v_res;

  RETURN v_res;
END $function$;;
