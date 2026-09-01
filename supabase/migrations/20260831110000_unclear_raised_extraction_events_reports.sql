-- Extract PN Reports tab: two more reports backed by qvm_new_apps.quotation_item_extraction_events,
-- counting event_type = 'unclear_raised' events over a fixed trailing 1-month window (the tab's
-- shared Date From/To filter does not apply here, per explicit request — only the branch filter
-- does), same precedent as get_monthly_po_vs_invoice_report's fixed rolling window.
-- 1. Count of 'unclear_raised' events per user (quotation_item_extraction_events.actor).
-- 2. Count of 'unclear_raised' events per vehicle brand, joined via
--    quotation_item_extraction_events.quotation_item_id -> quotation_items.main_brand.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_unclear_raised_by_user_report(
  p_branch_id integer DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.event_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      ud.user_id,
      COALESCE(ud.user_name, ud.email) AS user_name,
      count(*) AS event_count
    FROM qvm_new_apps.quotation_item_extraction_events e
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = e.quotation_item_id
    LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = e.actor
    WHERE e.event_type = 'unclear_raised'
      AND e.created_at >= date_trunc('day', now()) - interval '1 month'
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
    GROUP BY ud.user_id, ud.user_name, ud.email
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unclear_raised_by_user_report(integer) TO authenticated;


CREATE OR REPLACE FUNCTION qvm_new_apps.get_unclear_raised_by_brand_report(
  p_branch_id integer DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.event_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      qi.main_brand AS brand_id,
      ld.list_data AS brand_name,
      count(*) AS event_count
    FROM qvm_new_apps.quotation_item_extraction_events e
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = e.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
    WHERE e.event_type = 'unclear_raised'
      AND e.created_at >= date_trunc('day', now()) - interval '1 month'
      AND qi.main_brand IS NOT NULL
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
    GROUP BY qi.main_brand, ld.list_data
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unclear_raised_by_brand_report(integer) TO authenticated;
