-- Management Overview → "Management Reports" tab: rebuild get_lifecycle_stage_durations to use
-- PRIMARY business records instead of any log table, wherever a primary record exists — since a
-- confirmed_orders/purchase_orders/delivery_notes row is a mandatory, unconditional part of doing
-- that action (unlike status_logs/activity_log, both of which can silently miss a real event — see
-- this session's own findings: status_logs never records several statuses at all, and activity_log
-- only writes a row if a notification recipient happens to resolve, which is not guaranteed).
-- No new triggers or schema changes — this only reads what already exists, so it's safe to apply to
-- already-created quotations.
--
--   Confirmed -> Processing: confirmed_orders.created_at -> purchase_orders.created_at. Every
--     confirmed order has exactly one confirmed_orders row; every PO has exactly one purchase_orders
--     row. Both are set unconditionally by create_purchase_orders_anditems in the same call —
--     fully reliable, not a sample.
--   Processing -> Delivered: purchase_orders.created_at -> delivery_notes.created_at. Same
--     reasoning — delivery_notes is the actual delivery record, not an optional log.
--   Ready For Quotation -> Priced: the "Priced" side reuses the same primary-record approach
--     (quotation_vendor_items.updated_at, set atomically with .cost by the vendor's own pricing
--     save — a real business record, not a log). The "Ready For Quotation" side has no equivalent
--     primary record anywhere in the schema (item_status=235 is just a flag on quotation_items with
--     no dedicated table), so for that side only, every available signal is combined to maximize
--     coverage: status_logs entries (deduped for repeat-same-status noise), activity_log entries
--     (deduped for per-recipient duplication), and quotation_items.created_at as a last-resort
--     fallback for items currently sitting at 235 with no better logged entry. The most recent
--     candidate before the pricing event wins, so a real logged entry is always preferred over the
--     fallback when one exists.
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
    SELECT qi.quotation_item_id, qi.item_status, qi.created_at
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),

  -- ---------- Leg 1: Ready For Quotation -> Priced ----------
  priced_events AS (
    SELECT qvi.quotation_item_id, min(qvi.updated_at) AS entered_at
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN scoped_items si ON si.quotation_item_id = qvi.quotation_item_id
    WHERE qvi.cost IS NOT NULL AND qvi.updated_at > qvi.created_at
    GROUP BY qvi.quotation_item_id
  ),
  sl_logs AS (
    SELECT sl.quotation_item_id, sl.item_status, sl.created_at, sl.status_log_id
    FROM qvm_new_apps.status_logs sl
    JOIN scoped_items si ON si.quotation_item_id = sl.quotation_item_id
    WHERE sl.quotation_item_id IS NOT NULL
  ),
  sl_numbered AS (
    SELECT quotation_item_id, item_status, created_at,
      lag(item_status) OVER (PARTITION BY quotation_item_id ORDER BY created_at, status_log_id) AS prev_status
    FROM sl_logs
  ),
  sl_grp AS (
    SELECT *, sum(CASE WHEN item_status IS DISTINCT FROM prev_status THEN 1 ELSE 0 END)
      OVER (PARTITION BY quotation_item_id ORDER BY created_at) AS grp_id
    FROM sl_numbered
  ),
  sl_235 AS (
    SELECT quotation_item_id, min(created_at) AS entered_at
    FROM sl_grp WHERE item_status = 235
    GROUP BY quotation_item_id, grp_id
  ),
  al_235 AS (
    SELECT DISTINCT al.quotation_item_id, al.created_at AS entered_at
    FROM qvm_new_apps.activity_log al
    JOIN scoped_items si ON si.quotation_item_id = al.quotation_item_id
    WHERE al.action = 'status_change' AND (al.new_values ->> 'item_status')::integer = 235
  ),
  created_235_fallback AS (
    SELECT quotation_item_id, created_at AS entered_at
    FROM scoped_items WHERE item_status = 235
  ),
  entered_235_candidates AS (
    SELECT quotation_item_id, entered_at FROM sl_235
    UNION
    SELECT quotation_item_id, entered_at FROM al_235
    UNION
    SELECT quotation_item_id, entered_at FROM created_235_fallback
  ),
  leg1 AS (
    SELECT extract(epoch FROM (pe.entered_at - c.entered_at)) AS seconds
    FROM priced_events pe
    JOIN LATERAL (
      SELECT entered_at FROM entered_235_candidates ec
      WHERE ec.quotation_item_id = pe.quotation_item_id AND ec.entered_at < pe.entered_at
      ORDER BY entered_at DESC LIMIT 1
    ) c ON true
  ),

  -- ---------- Leg 2: Confirmed -> Processing (fully primary-record based) ----------
  leg2 AS (
    SELECT extract(epoch FROM (po.created_at - co.created_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    WHERE po.created_at > co.created_at
  ),

  -- ---------- Leg 3: Processing -> Delivered (fully primary-record based) ----------
  leg3 AS (
    SELECT extract(epoch FROM (dn.created_at - po.created_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.delivery_notes dn ON dn.confirmed_item_id = ci.confirmed_item_id
    WHERE dn.created_at > po.created_at
  ),

  combined AS (
    SELECT 1 AS ord, 'Ready For Quotation' AS from_label, 'Priced' AS to_label, count(*) AS n, sum(seconds) AS total_seconds
    FROM leg1 WHERE seconds > 0
    UNION ALL
    SELECT 2, 'Confirmed', 'Processing', count(*), sum(seconds) FROM leg2
    UNION ALL
    SELECT 3, 'Processing', 'Delivered', count(*), sum(seconds) FROM leg3
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
