-- Management Overview → "Management Reports" tab: per-client-branch RFQ (quotation) counts,
-- for the heat map + branch breakdown list. A branch is derived the same way
-- get_internal_dashboard does it — quotations has no customer_id column itself; the branch is
-- taken from quotation_items.customer_id, matched against client_branches.customer_id.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_branch_rfq_heatmap(
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
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.quotation_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.branch_name,
      cb.city,
      cb.region_id,
      ld_region.list_data AS region_name,
      (
        SELECT count(DISTINCT qi.quotation_id)
        FROM qvm_new_apps.quotation_items qi
        JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
        WHERE qi.customer_id = cb.customer_id
          AND (p_date_from IS NULL OR q.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      ) AS quotation_count
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.list_data ld_region ON ld_region.list_data_id = cb.region_id
    WHERE (p_branch_id IS NULL OR cb.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR cb.customer_id = ANY(v_branch_scope))
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_branch_rfq_heatmap(integer, timestamptz, timestamptz) TO authenticated;
