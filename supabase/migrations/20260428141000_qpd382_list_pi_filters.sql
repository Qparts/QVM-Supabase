-- QPD-382: List filter options for Purchase & Return Invoices dashboard
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.list_purchase_invoices_filters()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  result jsonb;
BEGIN
  WITH ams AS (
    SELECT DISTINCT q.account_manager AS id, ud.user_name AS name
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = q.account_manager
    WHERE q.account_manager IS NOT NULL
  ), sups AS (
    SELECT DISTINCT ld.list_data_id AS id, ld.list_data AS name
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qvi.vendor_id
    WHERE qvi.vendor_id IS NOT NULL
  )
  SELECT jsonb_build_object(
    'account_managers', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.name) FROM ams t), '[]'::jsonb),
    'suppliers', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.name) FROM sups t), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.list_purchase_invoices_filters() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_purchase_invoices_filters() TO authenticated;

COMMIT;
