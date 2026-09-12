-- The quotation context says which of its companies are the caller's own.
--
-- Whoever opens the RFQ form sees their workshops and every company those workshops serve — which
-- is the point of the workshop tier, and is deliberately wider than the caller's own companies: a
-- workshop shared with another company can raise that company's work out of the same branches.
--
-- What was missing is the distinction. The picker listed a caller's own company beside companies
-- they only reach through a shared workshop, with nothing to tell them apart, so choosing who the
-- job is billed to was guesswork on a list where every entry looked equally like home.

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
    -- Which of the companies below are the caller's own. A workshop serves several, so the list
    -- rightly includes companies the caller does not belong to — this says which is which, rather
    -- than presenting a stranger's company as indistinguishable from their own.
    'own_company_ids', COALESCE((
      SELECT jsonb_agg(DISTINCT c) FROM (
        SELECT uc.company_id AS c FROM qvm_new_apps.user_companies uc WHERE uc.user_id = v_uid
        UNION
        SELECT w.company_id FROM qvm_new_apps.user_workshops uw
          JOIN qvm_new_apps.client_workshops w ON w.workshop_id = uw.workshop_id
         WHERE uw.user_id = v_uid AND w.company_id IS NOT NULL
        UNION
        SELECT wc.company_id FROM qvm_new_apps.user_workshops uw
          JOIN qvm_new_apps.workshop_companies wc ON wc.workshop_id = uw.workshop_id
         WHERE uw.user_id = v_uid
      ) s WHERE c IS NOT NULL), '[]'::jsonb),
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
       -- An unrestricted internal user has the old picker over every client; this list is for
       -- everyone whose choice is genuinely narrowed — a Company Admin included, who is internal
       -- and scoped at the same time.
       AND v_branches IS NOT NULL), '[]'::jsonb)
  ));
END $$;

CREATE OR REPLACE FUNCTION public.get_quotation_context() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.get_quotation_context() $$;

REVOKE ALL ON FUNCTION public.get_quotation_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_quotation_context() TO authenticated;
