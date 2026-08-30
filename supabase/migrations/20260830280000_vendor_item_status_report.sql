-- Vendor Performance Reports tab: per-vendor stacked bar of quotation_vendor_items counts by
-- status, keyed off qvm_new_apps.quotation_vendor_items.vendor_item_status (the vendor_status
-- list, list_id distinct from the RFQ/Order status list_id=3 used elsewhere in this tab).
--
-- Bucketing, verified live against real vendor_item_status values (only 157/158/161/NULL actually
-- occur today — 159/160/162-169/207 have zero live rows, so their bucketing is a documented
-- judgment call, not something confirmable against current data):
--   New        = NULL (row created, no response yet) OR 157 "طلب تسعير" (pricing request)
--   Priced     = 158 "تم التسعير"
--   Unavailable= 161 "غير متوفر"
--   Returned   = 167 "تم الارجاع" (completed return, as opposed to 166 "طلب ارجاع" which is a
--                still-open return request and falls into Pending below)
--   Pending    = everything else (159 confirmed-request, 160 cancelled, 162 processing,
--                163 ready-for-pickup, 165 invoice-uploaded, 166 return-requested,
--                168 return-invoice-uploaded, 169 settled, 207 confirm-previous-price) — a
--                catch-all so the 5 buckets are a complete partition of every row, matching this
--                tab's own get_branch_order_status_report precedent.
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
      count(*) FILTER (WHERE c.bucket = 'priced') AS priced_count,
      count(*) FILTER (WHERE c.bucket = 'pending') AS pending_count,
      count(*) FILTER (WHERE c.bucket = 'unavailable') AS unavailable_count,
      count(*) FILTER (WHERE c.bucket = 'returned') AS returned_count,
      count(*) AS total_count
    FROM classified c
    JOIN qvm_new_apps.vendors v ON v.vendor_id = c.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_item_status_report(integer, timestamptz, timestamptz) TO authenticated;
