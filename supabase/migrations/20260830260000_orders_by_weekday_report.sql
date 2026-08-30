-- Management Overview → "Management Reports" tab: seventh report block — count of orders
-- (quotations) per day of the week, Saturday through Friday (Gulf week order, matching the
-- reference design). Day of week is computed in Asia/Riyadh local time, consistent with the
-- timezone convention already used elsewhere in this codebase (e.g. sign_delivery_note,
-- seconds_excluding_fridays). Branch derivation and date filtering follow the same pattern as
-- get_branch_rfq_heatmap — a quotation is counted once per branch it touches.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_orders_by_weekday(
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

  WITH scoped_quotations AS (
    SELECT DISTINCT q.quotation_id, q.created_at
    FROM qvm_new_apps.quotations q
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = q.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  counts AS (
    SELECT extract(dow FROM (created_at AT TIME ZONE 'Asia/Riyadh'))::integer AS dow, count(*) AS n
    FROM scoped_quotations
    GROUP BY 1
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_agg(to_jsonb(r) ORDER BY r.ord)
  ) INTO v_result
  FROM (
    SELECT g.ord, g.dow, g.day_label, COALESCE(c.n, 0) AS order_count
    FROM (VALUES
      (1, 6, 'Saturday'),
      (2, 0, 'Sunday'),
      (3, 1, 'Monday'),
      (4, 2, 'Tuesday'),
      (5, 3, 'Wednesday'),
      (6, 4, 'Thursday'),
      (7, 5, 'Friday')
    ) AS g(ord, dow, day_label)
    LEFT JOIN counts c ON c.dow = g.dow
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_orders_by_weekday(integer, timestamptz, timestamptz) TO authenticated;
