-- "Requests per Vendor by Status" report: already counts quotation_vendor_items per status bucket
-- (item-level). Adds the paired vendor-quotation (request) count per bucket — i.e. how many
-- distinct quotation_vendor_id rows hold those items — beside each item count.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_item_status_report(
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

  WITH scoped_items AS (
    SELECT DISTINCT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  classified AS (
    SELECT
      qvi.vendor_id,
      qvi.quotation_vendor_id,
      CASE
        WHEN qvi.vendor_item_status IS NULL OR qvi.vendor_item_status = 157 THEN 'new'
        WHEN qvi.vendor_item_status = 158 THEN 'priced'
        WHEN qvi.vendor_item_status = 161 THEN 'unavailable'
        WHEN qvi.vendor_item_status = 167 THEN 'returned'
        ELSE 'pending'
      END AS bucket
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN scoped_items si ON si.quotation_item_id = qvi.quotation_item_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.total_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      count(*) FILTER (WHERE c.bucket = 'new') AS new_count,
      count(DISTINCT c.quotation_vendor_id) FILTER (WHERE c.bucket = 'new') AS new_requests,
      count(*) FILTER (WHERE c.bucket = 'priced') AS priced_count,
      count(DISTINCT c.quotation_vendor_id) FILTER (WHERE c.bucket = 'priced') AS priced_requests,
      count(*) FILTER (WHERE c.bucket = 'pending') AS pending_count,
      count(DISTINCT c.quotation_vendor_id) FILTER (WHERE c.bucket = 'pending') AS pending_requests,
      count(*) FILTER (WHERE c.bucket = 'unavailable') AS unavailable_count,
      count(DISTINCT c.quotation_vendor_id) FILTER (WHERE c.bucket = 'unavailable') AS unavailable_requests,
      count(*) FILTER (WHERE c.bucket = 'returned') AS returned_count,
      count(DISTINCT c.quotation_vendor_id) FILTER (WHERE c.bucket = 'returned') AS returned_requests,
      count(*) AS total_count
    FROM classified c
    JOIN qvm_new_apps.vendors v ON v.vendor_id = c.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_item_status_report(integer, timestamptz, timestamptz) TO authenticated;
