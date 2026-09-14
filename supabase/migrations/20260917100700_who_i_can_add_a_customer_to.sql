-- The vendors and workshops the caller can add a customer to, and the insurers to name one after.
--
-- On the tree, that context is the pane you clicked through to get there. On the flat customers
-- page there is no such pane, and a customer still has to belong to somebody — so the create form
-- asks, and this is what it asks with.
--
-- Both halves in one call: the form needs the insurance list too, and two round trips to fill one
-- dialog is one too many.

CREATE OR REPLACE FUNCTION qvm_new_apps.my_customer_owners()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'owners', COALESCE((
      SELECT jsonb_agg(o ORDER BY o->>'owner_kind', o->>'display_name')
      FROM (
        SELECT jsonb_build_object(
                 'owner_kind', 'workshop', 'owner_id', w.workshop_id,
                 'display_name', vw.name, 'code', w.workshop_code) AS o
          FROM qvm_new_apps.client_workshops w
          JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
         WHERE qvm_new_apps.can_admin_workshop(w.workshop_id)
        UNION ALL
        SELECT jsonb_build_object(
                 'owner_kind', 'vendor', 'owner_id', v.vendor_id,
                 'display_name', vv.name, 'code', v.vendor_code)
          FROM qvm_new_apps.vendors v
          JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
         WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
      ) s), '[]'::jsonb),
    'insurance_companies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', ic.id, 'name', ic.name) ORDER BY ic.name)
        FROM qvm_new_apps.insurance_companies ic), '[]'::jsonb)));
END $$;

CREATE OR REPLACE FUNCTION public.my_customer_owners() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.my_customer_owners() $$;

REVOKE ALL ON FUNCTION public.my_customer_owners() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_customer_owners() TO authenticated;
