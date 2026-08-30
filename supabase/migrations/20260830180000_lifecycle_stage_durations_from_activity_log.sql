-- Management Overview → "Management Reports" tab: rebuild get_lifecycle_stage_durations on top of
-- qvm_new_apps.activity_log instead of the fragile per-table proxy timestamps used previously.
--
-- activity_log is populated by an AFTER UPDATE trigger on both quotation_items and confirmed_items
-- (trg_dispatch_notification_rules_qi/_ci, 20260810100000_activity_log.sql) that WHEN
-- (NEW.item_status IS DISTINCT FROM OLD.item_status) records old_values->>'item_status' and
-- new_values->>'item_status' directly — a real old→new pair, unlike status_logs (which only ever
-- records the new status, and only logs 4 of the ~10 statuses in this pipeline at all). Verified
-- live: activity_log actually has rows for every transition below except leg 3.
--
-- Two things must be handled before using it:
--   1. It duplicates each real event once per notified recipient (owner_user_id) — 125 raw rows
--      collapse to 49 distinct (quotation_item_id, old_status, new_status, created_at) events live.
--      Always de-duplicate on that tuple first.
--   2. Both quotation_items- and confirmed_items-sourced rows for the SAME underlying change carry
--      the same created_at (multiple now() calls in one transaction return an identical value in
--      Postgres), so UNIONing both source tables and de-duplicating on the same tuple naturally
--      collapses same-instant qi/ci duplicates too — no special-casing needed.
--
-- Legs 1,2,4,5,6 match the exact (old_status, new_status) pair directly from activity_log — safe
-- because these events are real logged transitions, not inferred from adjacent rows. Leg 7 handles
-- the fact that Processing sometimes passes through "Out for Delivery" (22) before Delivered (23):
-- it takes each item's first-ever entry into 21 and first-ever entry into 23 (only when the latter
-- is after the former), rather than requiring a direct 21→23 hop that rarely occurs. Leg 3 (Added by
-- Vendor → Sent To Vendor) has zero matching events live — the 5 items currently sitting at status
-- 267 haven't been approved yet, so there is genuinely nothing to report yet, not a query gap.
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
      (al.old_values ->> 'item_status')::integer AS old_status,
      (al.new_values ->> 'item_status')::integer AS new_status,
      al.created_at
    FROM qvm_new_apps.activity_log al
    JOIN scoped_items si ON si.quotation_item_id = al.quotation_item_id
    WHERE al.action = 'status_change'
      AND al.old_values ? 'item_status'
      AND al.new_values ? 'item_status'
  ),
  -- No activity_log event captures "entered 236" (items are created directly at that status, and
  -- creation isn't an UPDATE, so the trigger never fires for it) — quotation_items.created_at is
  -- the only available entry-side timestamp here, paired with the real, activity_log-confirmed
  -- 236→235 exit event.
  leg1 AS (
    SELECT extract(epoch FROM (e.created_at - qi.created_at)) AS seconds
    FROM events e
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = e.quotation_item_id
    WHERE e.old_status = 236 AND e.new_status = 235 AND e.created_at > qi.created_at
  ),
  leg2 AS (SELECT quotation_item_id, created_at FROM events WHERE old_status = 235 AND new_status = 237),
  leg3 AS (SELECT quotation_item_id, created_at FROM events WHERE old_status = 267 AND new_status = 237),
  leg4 AS (SELECT quotation_item_id, created_at FROM events WHERE old_status = 237 AND new_status = 17),
  leg5 AS (SELECT quotation_item_id, created_at FROM events WHERE old_status = 17 AND new_status = 19),
  leg6 AS (SELECT quotation_item_id, created_at FROM events WHERE old_status = 19 AND new_status = 21),
  entered_21 AS (SELECT quotation_item_id, min(created_at) AS entered_at FROM events WHERE new_status = 21 GROUP BY quotation_item_id),
  entered_23 AS (SELECT quotation_item_id, min(created_at) AS entered_at FROM events WHERE new_status = 23 GROUP BY quotation_item_id),
  leg7 AS (
    SELECT extract(epoch FROM (e23.entered_at - e21.entered_at)) AS seconds
    FROM entered_21 e21
    JOIN entered_23 e23 ON e23.quotation_item_id = e21.quotation_item_id
    WHERE e23.entered_at > e21.entered_at
  ),
  -- legs 2/3/4/5/6 need each event paired against the item's immediately-preceding event of the
  -- expected "from" status, so a bounced-back item (e.g. sent to vendor, back to Ready For
  -- Quotation, sent again) doesn't get paired with a stale/unrelated earlier timestamp.
  paired AS (
    SELECT 2 AS ord, e.quotation_item_id, extract(epoch FROM (e.created_at - p.created_at)) AS seconds
    FROM leg2 e
    JOIN LATERAL (
      SELECT created_at FROM events
      WHERE quotation_item_id = e.quotation_item_id AND new_status = 235 AND created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    UNION ALL
    SELECT 3, e.quotation_item_id, extract(epoch FROM (e.created_at - p.created_at))
    FROM leg3 e
    JOIN LATERAL (
      SELECT created_at FROM events
      WHERE quotation_item_id = e.quotation_item_id AND new_status = 267 AND created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    UNION ALL
    SELECT 4, e.quotation_item_id, extract(epoch FROM (e.created_at - p.created_at))
    FROM leg4 e
    JOIN LATERAL (
      SELECT created_at FROM events
      WHERE quotation_item_id = e.quotation_item_id AND new_status = 237 AND created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    UNION ALL
    SELECT 5, e.quotation_item_id, extract(epoch FROM (e.created_at - p.created_at))
    FROM leg5 e
    JOIN LATERAL (
      SELECT created_at FROM events
      WHERE quotation_item_id = e.quotation_item_id AND new_status = 17 AND created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
    UNION ALL
    SELECT 6, e.quotation_item_id, extract(epoch FROM (e.created_at - p.created_at))
    FROM leg6 e
    JOIN LATERAL (
      SELECT created_at FROM events
      WHERE quotation_item_id = e.quotation_item_id AND new_status = 19 AND created_at < e.created_at
      ORDER BY created_at DESC LIMIT 1
    ) p ON true
  ),
  combined AS (
    SELECT 1 AS ord, 'Extract PN' AS from_label, 'Ready For Quotation' AS to_label, count(*) AS n, sum(seconds) AS total_seconds
    FROM leg1 WHERE seconds IS NOT NULL AND seconds > 0
    UNION ALL
    SELECT ord,
      CASE ord WHEN 2 THEN 'Ready For Quotation' WHEN 3 THEN 'Added by Vendor' WHEN 4 THEN 'Sent To Vendor' WHEN 5 THEN 'Priced' WHEN 6 THEN 'Confirmed' END,
      CASE ord WHEN 2 THEN 'Sent To Vendor' WHEN 3 THEN 'Sent To Vendor' WHEN 4 THEN 'Priced' WHEN 5 THEN 'Confirmed' WHEN 6 THEN 'Processing' END,
      count(*), sum(seconds)
    FROM paired
    WHERE seconds > 0
    GROUP BY ord
    UNION ALL
    SELECT 7, 'Processing', 'Delivered', count(*), sum(seconds) FROM leg7
  ),
  -- ensure all 7 legs are always present, even ones with zero matching rows above
  all_legs AS (
    SELECT g.ord, g.from_label, g.to_label, c.n, c.total_seconds
    FROM (VALUES
      (1, 'Extract PN', 'Ready For Quotation'),
      (2, 'Ready For Quotation', 'Sent To Vendor'),
      (3, 'Added by Vendor', 'Sent To Vendor'),
      (4, 'Sent To Vendor', 'Priced'),
      (5, 'Priced', 'Confirmed'),
      (6, 'Confirmed', 'Processing'),
      (7, 'Processing', 'Delivered')
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
