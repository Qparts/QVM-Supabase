-- Fix qvm_new_apps.get_lifecycle_stage_durations: "Priced" (item_status = 17) means the CLIENT
-- SELLING price was set on quotation_items — NOT the vendor's cost on quotation_vendor_items.
-- The previous migration (20260830200000) wrongly used quotation_vendor_items.updated_at as the
-- "Priced" boundary, which actually measures "vendor quoted a cost," a different, earlier milestone.
--
-- The RPC that saves the selling price (update_quotation_item_prices/_bulk) is not defined in this
-- repo's migration history (pre-dates it / lives only on prod) — its body can't be inspected, and it
-- can't safely be modified blind. No dedicated timestamp for "selling price saved" exists anywhere
-- in the schema without adding a new column/trigger, which the user explicitly does not want.
--
-- Best available real signal without any DB changes: qvm_new_apps.activity_log's actual
-- new_values->>'item_status' = '17' events — this directly records the item_status column
-- transitioning to 17, whatever RPC caused it. Verified this is trustworthy specifically for 17:
-- status_logs has ZERO rows with item_status = 17, ever. change_item_status_bulk (the one other
-- mechanism that can set item_status to 17, for reasons unrelated to price — "a manually-set status
-- staff toggle by hand") ALSO always logs to status_logs when it fires. Since no 17-transition has
-- ever appeared in status_logs, change_item_status_bulk has never actually been used to set status
-- 17 in this database's history — so every 17-transition activity_log has recorded is guaranteed to
-- have come from the real selling-price-save action, not toggle noise.
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
    SELECT DISTINCT al.quotation_item_id, al.created_at AS entered_at
    FROM qvm_new_apps.activity_log al
    JOIN scoped_items si ON si.quotation_item_id = al.quotation_item_id
    WHERE al.action = 'status_change' AND (al.new_values ->> 'item_status')::integer = 17
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

  -- ---------- Leg 2: Confirmed -> Processing (fully primary-record based, unchanged) ----------
  leg2 AS (
    SELECT extract(epoch FROM (po.created_at - co.created_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    WHERE po.created_at > co.created_at
  ),

  -- ---------- Leg 3: Processing -> Delivered (fully primary-record based, unchanged) ----------
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
