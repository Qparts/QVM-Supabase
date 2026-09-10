-- What the person raising an order may choose from.
--
-- A workshop user picks a company and then one of their branches. Both lists depend on who they
-- are, and neither can be assembled in the browser: the companies come from the workshops they
-- belong to, and the branches from those same workshops. Sending the whole client tree to a
-- workshop user to filter client-side would hand them every other company in the platform.
--
-- Shaped by workshop rather than as two flat lists, because the two are not independent: a user in
-- two workshops, only one of which serves Alalamiya, must not be offered the other's branches once
-- Alalamiya is chosen.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_context()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_type int;
  v_branches integer[];
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT user_type INTO v_type FROM qvm_new_apps.user_data WHERE user_id = v_uid;
  v_branches := qvm_new_apps.effective_branch_ids(v_uid);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    -- NULL means unrestricted, which is an internal user: they keep the existing company picker
    -- over every company, and this call only tells them so.
    'is_internal', v_type = 185,
    'unrestricted', v_branches IS NULL,
    'workshops', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'workshop_id', w.workshop_id,
               'name', vw.name,
               'companies', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object('company_id', vc.company_id, 'name', vc.name)
                                  ORDER BY vc.name)
                   FROM qvm_new_apps.workshop_companies wc
                   JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = wc.company_id
                  WHERE wc.workshop_id = w.workshop_id), '[]'::jsonb),
               'branches', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'customer_id', vb.customer_id,
                          'name', vb.name,
                          'city', vb.city,
                          'readiness', qvm_new_apps.branch_quotation_readiness(vb.customer_id))
                        ORDER BY vb.name)
                   FROM qvm_new_apps.v_client_branches vb
                  WHERE vb.workshop_id = w.workshop_id
                    -- Only the branches this user actually has. A branch manager sees one; a
                    -- workshop user sees all of their workshop's.
                    AND (v_branches IS NULL OR vb.customer_id = ANY(v_branches))), '[]'::jsonb)
             ) ORDER BY vw.name)
      FROM qvm_new_apps.client_workshops w
      JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
     WHERE w.is_active
       AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb
                    WHERE cb.workshop_id = w.workshop_id
                      AND (v_branches IS NULL OR cb.customer_id = ANY(v_branches)))
       -- An internal user with no restriction has the old picker; this list is for the people
       -- whose choice is genuinely narrowed by which workshops they belong to.
       AND v_branches IS NOT NULL), '[]'::jsonb)
  ));
END $$;

CREATE OR REPLACE FUNCTION public.get_quotation_context() RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.get_quotation_context(); $$;
GRANT EXECUTE ON FUNCTION public.get_quotation_context() TO authenticated;
