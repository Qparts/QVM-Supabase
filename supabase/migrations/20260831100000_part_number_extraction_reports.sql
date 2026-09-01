-- Extract PN Reports tab: two reports backed by qvm_new_apps.part_number_extraction_logs.
-- 1. Count of part numbers extracted per user.
-- 2. Average extraction duration (empty_since -> empty_until, in minutes) per vehicle brand, joined
--    via part_number_extraction_logs.quotation_item_id -> quotation_items.main_brand.
-- Both scoped/filterable by branch (via quotation_items.customer_id) and date range (via
-- part_number_extraction_logs.created_at, when the extraction was logged), matching every other
-- report RPC's filter bar this session.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_part_number_extraction_by_user_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
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
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.extraction_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      ud.user_id,
      COALESCE(ud.user_name, ud.email) AS user_name,
      count(*) AS extraction_count
    FROM qvm_new_apps.part_number_extraction_logs pnel
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = pnel.quotation_item_id
    LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = pnel.user_id
    WHERE (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
      AND (p_date_from IS NULL OR pnel.created_at >= p_date_from)
      AND (p_date_to IS NULL OR pnel.created_at <= p_date_to)
    GROUP BY ud.user_id, ud.user_name, ud.email
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_part_number_extraction_by_user_report(integer, timestamptz, timestamptz) TO authenticated;


CREATE OR REPLACE FUNCTION qvm_new_apps.get_part_number_extraction_avg_time_by_brand_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
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
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.avg_minutes DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      qi.main_brand AS brand_id,
      ld.list_data AS brand_name,
      count(*) AS extraction_count,
      round((avg(extract(epoch FROM (pnel.empty_until - pnel.empty_since))) / 60.0)::numeric, 1) AS avg_minutes
    FROM qvm_new_apps.part_number_extraction_logs pnel
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = pnel.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
    WHERE pnel.empty_until IS NOT NULL
      AND qi.main_brand IS NOT NULL
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
      AND (p_date_from IS NULL OR pnel.created_at >= p_date_from)
      AND (p_date_to IS NULL OR pnel.created_at <= p_date_to)
    GROUP BY qi.main_brand, ld.list_data
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_part_number_extraction_avg_time_by_brand_report(integer, timestamptz, timestamptz) TO authenticated;
