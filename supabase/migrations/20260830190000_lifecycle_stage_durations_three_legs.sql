-- Management Overview → "Management Reports" tab: narrow get_lifecycle_stage_durations down to
-- exactly the 3 transitions requested: Ready For Quotation → Priced, Confirmed → Processing,
-- Processing → Delivered. Still built on qvm_new_apps.activity_log (see
-- 20260830180000_lifecycle_stage_durations_from_activity_log.sql's header for why — status_logs
-- has zero rows for Priced(17)/Processing(21)/Delivered(23), confirmed live, so none of these 3
-- transitions could show any data if built on it).
--
-- Each leg is computed by matching every arrival at the "to" status with the most recent prior
-- arrival at the "from" status for the same item (a LATERAL "last entry before this one" join),
-- rather than a strict single-hop pair match:
--   - Ready For Quotation → Priced: an item can reach Priced(17) either directly from 235 or via
--     Sent To Vendor (235→237→17) — verified live, both paths occur. Matching on "last time this
--     item entered 235 before it got priced" correctly captures the full RFQ-side time regardless
--     of which path it took, and correctly rules out arriving-at-17 events for items that never
--     passed through 235 first (no LATERAL match → excluded, not a fabricated duration).
--   - Confirmed → Processing / Processing → Delivered: straightforward, since 19→21→22→23 is a
--     one-directional post-confirmation pipeline; the "last entry" join naturally collapses through
--     the "Out for Delivery"(22) micro-stage between Processing and Delivered.
-- Ready For Quotation → Priced additionally needs a real LATERAL match (not simple first-occurrence
-- timestamps) because items can legitimately bounce backward (17→235, observed live) — pairing each
-- pricing event with its own immediately-preceding Ready-For-Quotation entry avoids misattributing
-- duration across separate pricing cycles on the same item.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_lifecycle_stage_durations(
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
  events AS (
    SELECT DISTINCT
      al.quotation_item_id,
      (al.new_values ->> 'item_status')::integer AS new_status,
      al.created_at
    FROM qvm_new_apps.activity_log al
    JOIN scoped_items si ON si.quotation_item_id = al.quotation_item_id
    WHERE al.action = 'status_change'
      AND al.new_values ? 'item_status'
  ),
  legs AS (
    SELECT 1 AS ord, 'Ready For Quotation' AS from_label, 'Priced' AS to_label,
      extract(epoch FROM (e.created_at - p.created_at)) AS seconds
    FROM events e
    JOIN LATERAL (
      SELECT created_at FROM events ev
      WHERE ev.quotation_item_id = e.quotation_item_id AND ev.new_status = 235 AND ev.created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    WHERE e.new_status = 17

    UNION ALL

    SELECT 2, 'Confirmed', 'Processing',
      extract(epoch FROM (e.created_at - p.created_at))
    FROM events e
    JOIN LATERAL (
      SELECT created_at FROM events ev
      WHERE ev.quotation_item_id = e.quotation_item_id AND ev.new_status = 19 AND ev.created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    WHERE e.new_status = 21

    UNION ALL

    SELECT 3, 'Processing', 'Delivered',
      extract(epoch FROM (e.created_at - p.created_at))
    FROM events e
    JOIN LATERAL (
      SELECT created_at FROM events ev
      WHERE ev.quotation_item_id = e.quotation_item_id AND ev.new_status = 21 AND ev.created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    WHERE e.new_status = 23
  ),
  combined AS (
    SELECT ord, from_label, to_label, count(*) AS n, sum(seconds) AS total_seconds
    FROM legs
    WHERE seconds > 0
    GROUP BY ord, from_label, to_label
  ),
  all_legs AS (
    SELECT g.ord, g.from_label, g.to_label, c.n, c.total_seconds
    FROM (VALUES
      (1, 'Ready For Quotation', 'Priced'),
      (2, 'Confirmed', 'Processing'),
      (3, 'Processing', 'Delivered')
    ) AS g(ord, from_label, to_label)
    LEFT JOIN combined c ON c.ord = g.ord
  ),
  grand_total AS (
    SELECT NULLIF(sum(total_seconds), 0) AS total_seconds FROM all_legs WHERE total_seconds IS NOT NULL
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.ord), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      al.ord,
      al.from_label,
      al.to_label,
      COALESCE(al.n, 0) AS transition_count,
      CASE WHEN al.total_seconds IS NULL THEN NULL ELSE round((al.total_seconds / 3600.0)::numeric, 1) END AS total_hours,
      CASE WHEN al.total_seconds IS NULL OR al.n = 0 THEN NULL ELSE round((al.total_seconds / 3600.0 / al.n)::numeric, 1) END AS avg_hours,
      CASE WHEN al.total_seconds IS NULL OR gt.total_seconds IS NULL THEN NULL
           ELSE round((al.total_seconds / gt.total_seconds * 100)::numeric, 1) END AS pct_of_total
    FROM all_legs al
    CROSS JOIN grand_total gt
  ) r;

  RETURN v_result;
END;
$function$;
