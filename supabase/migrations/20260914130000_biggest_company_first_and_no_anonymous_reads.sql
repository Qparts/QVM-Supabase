-- Biggest company first, newest second.
--
-- The previous ordering had these the other way round. In practice that put every company carried
-- over from list 1 into one undifferentiated block — the backfill stamped them all with the same
-- created_at — and left size to decide only within it. Leading with size sorts the whole list by
-- how much is actually going on in each company, and age settles the ties.

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
        -- Biggest first: the company with the most workshops is the one with the most going on,
        -- and it is where the work is. Age breaks the tie, so among companies of equal size the
        -- newest is on top, and the name settles the rest.
        SELECT jsonb_agg(co ORDER BY s.workshop_count DESC, s.created_at DESC NULLS LAST, co->>'display_name')
        FROM (
          SELECT jsonb_build_object(
            'company_id', c.company_id,
            'display_name', vc.name,
            'created_at', c.created_at,
            'workshop_count', (SELECT count(*) FROM qvm_new_apps.workshop_companies wc
                                WHERE wc.company_id = c.company_id),
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
          ) AS co,
          c.created_at,
          (SELECT count(*) FROM qvm_new_apps.workshop_companies wc
            WHERE wc.company_id = c.company_id)::int AS workshop_count
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


-- While confirming the deploy had landed, an anonymous request — the anon key, no user — reached
-- list_cities and list_districts and got answers.
--
-- The cause is a default rather than a mistake in these particular functions: a function created in
-- `public` is executable by PUBLIC unless that is taken away, and granting EXECUTE to `authenticated`
-- adds a grant without removing the one already there. Every function this branch added carried the
-- grant and not the revoke.
--
-- Nothing leaked. The two that answered return the names and coordinates of Saudi cities, which are
-- public facts, and the three admin functions refused on their own — their bodies ask
-- can_admin_branch, and auth.uid() is NULL for an anonymous caller, so the answer is no. But a write
-- function should not be reachable at all by someone who is not signed in, and relying on the body
-- to notice is one edit away from not being true.

REVOKE ALL ON FUNCTION public.list_cities(integer, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_districts(integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_branch_addresses(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_save_branch_address(integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_branch_address_active(bigint, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.list_cities(integer, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_districts(integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_branch_addresses(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_branch_address(integer, bigint, text, text, integer, integer, text, text, text, numeric, numeric, boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_branch_address_active(bigint, boolean) TO authenticated;
