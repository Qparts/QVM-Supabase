-- Management Overview → "Management Reports" tab: redefine get_lifecycle_stage_durations to
-- return exactly the 7 named transitions the user asked for, in that fixed order, instead of
-- whatever pairs happened to appear in status_logs.
--
-- status_logs only ever logs 4 statuses live (Canceled/18, Confirmed/19, Ready For Quotation/235,
-- Sent To Vendor/237) — Extract PN(236), Added by Vendor(267), Priced(17), Processing(21) and
-- Delivered(23) are never written to it, even though items do reach those statuses. So only leg 2
-- below still reads status_logs; the other 6 legs use the best alternative real timestamp pair
-- found for each transition, each with a documented reliability caveat. Legs with zero matching
-- rows return NULL hours/pct rather than a fabricated 0%, so "no data yet" is visibly different
-- from "this stage takes no time."
--
--   1. Extract PN -> Ready For Quotation: quotation_items.pn_saved_at - .created_at (set atomically
--      by set_extract_pn). Live check: 0 rows have pn_saved_at populated yet — will show "no data."
--   2. Ready For Quotation -> Sent To Vendor: status_logs (235 -> 237), collapsed to dedupe repeat
--      same-status log rows (e.g. re-sending to more vendors re-logs 237 without a real transition).
--   3. Added by Vendor -> Sent To Vendor: quotation_items.updated_at - .created_at, for items
--      created by a vendor's own user_id (add_quotation_item_by_vendor sets created_by = the
--      vendor's uid) that have since moved off 267. Live check: 0 matching items — will show "no
--      data" (the 5 items currently at status 267 haven't been approved yet, so none have a
--      completed transition regardless of proxy).
--   4. Sent To Vendor -> Priced: quotation_vendor_items.updated_at - .created_at, where cost is
--      set — the same "did this vendor quote a price" signal used elsewhere in this tab, since
--      item_status = 17 is explicitly a manually-toggled, unreliable signal per
--      20260826100000_fix_get_internal_actions_fully_priced_vendor_cost.sql.
--   5. Priced -> Confirmed: confirmed_orders.created_at - the WINNING vendor's
--      quotation_vendor_items.updated_at (qvi.cost_id = qi.cost_id) — reuses leg 4's timestamp as
--      the "priced" boundary for the same reason (no reliable entry-into-17 timestamp exists).
--   6. Confirmed -> Processing: purchase_orders.created_at - confirmed_orders.created_at, both set
--      atomically by create_purchase_orders_anditems.
--   7. Processing -> Delivered: delivery_notes.created_at - purchase_orders.created_at. Live check:
--      only 2 delivery_notes rows exist — real but a small sample.
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
    SELECT qi.quotation_item_id, qi.quotation_id, qi.cost_id, qi.item_status,
           qi.created_at, qi.updated_at, qi.pn_saved_at, qi.created_by
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  leg1 AS (
    SELECT extract(epoch FROM (si.pn_saved_at - si.created_at)) AS seconds
    FROM scoped_items si
    WHERE si.pn_saved_at IS NOT NULL AND si.pn_saved_at > si.created_at
  ),
  logs AS (
    SELECT sl.quotation_item_id, sl.item_status, sl.created_at, sl.status_log_id
    FROM qvm_new_apps.status_logs sl
    JOIN scoped_items si ON si.quotation_item_id = sl.quotation_item_id
    WHERE sl.quotation_item_id IS NOT NULL
  ),
  numbered AS (
    SELECT
      quotation_item_id, item_status, created_at,
      lag(item_status) OVER (PARTITION BY quotation_item_id ORDER BY created_at, status_log_id) AS prev_status
    FROM logs
  ),
  grp AS (
    SELECT
      *,
      sum(CASE WHEN item_status IS DISTINCT FROM prev_status THEN 1 ELSE 0 END)
        OVER (PARTITION BY quotation_item_id ORDER BY created_at) AS grp_id
    FROM numbered
  ),
  collapsed AS (
    SELECT quotation_item_id, item_status, min(created_at) AS entered_at
    FROM grp
    GROUP BY quotation_item_id, grp_id, item_status
  ),
  seq AS (
    SELECT
      quotation_item_id, item_status, entered_at,
      lag(item_status) OVER (PARTITION BY quotation_item_id ORDER BY entered_at) AS prev_status,
      lag(entered_at) OVER (PARTITION BY quotation_item_id ORDER BY entered_at) AS prev_time
    FROM collapsed
  ),
  leg2 AS (
    SELECT extract(epoch FROM (entered_at - prev_time)) AS seconds
    FROM seq
    WHERE prev_status = 235 AND item_status = 237
  ),
  leg3 AS (
    SELECT extract(epoch FROM (si.updated_at - si.created_at)) AS seconds
    FROM scoped_items si
    JOIN qvm_new_apps.vendors v ON v.user_id = si.created_by
    WHERE si.item_status <> 267 AND si.updated_at > si.created_at
  ),
  leg4 AS (
    SELECT extract(epoch FROM (qvi.updated_at - qvi.created_at)) AS seconds
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN scoped_items si ON si.quotation_item_id = qvi.quotation_item_id
    WHERE qvi.cost IS NOT NULL AND qvi.updated_at > qvi.created_at
  ),
  leg5 AS (
    SELECT extract(epoch FROM (co.created_at - qvi.updated_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = si.cost_id
    WHERE qvi.cost IS NOT NULL AND co.created_at > qvi.updated_at
  ),
  leg6 AS (
    SELECT extract(epoch FROM (po.created_at - co.created_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    WHERE po.created_at > co.created_at
  ),
  leg7 AS (
    SELECT extract(epoch FROM (dn.created_at - po.created_at)) AS seconds
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.delivery_notes dn ON dn.confirmed_item_id = ci.confirmed_item_id
    WHERE dn.created_at > po.created_at
  ),
  combined AS (
    SELECT 1 AS ord, 'Extract PN' AS from_label, 'Ready For Quotation' AS to_label, count(*) AS n, sum(seconds) AS total_seconds FROM leg1
    UNION ALL
    SELECT 2, 'Ready For Quotation', 'Sent To Vendor', count(*), sum(seconds) FROM leg2
    UNION ALL
    SELECT 3, 'Added by Vendor', 'Sent To Vendor', count(*), sum(seconds) FROM leg3
    UNION ALL
    SELECT 4, 'Sent To Vendor', 'Priced', count(*), sum(seconds) FROM leg4
    UNION ALL
    SELECT 5, 'Priced', 'Confirmed', count(*), sum(seconds) FROM leg5
    UNION ALL
    SELECT 6, 'Confirmed', 'Processing', count(*), sum(seconds) FROM leg6
    UNION ALL
    SELECT 7, 'Processing', 'Delivered', count(*), sum(seconds) FROM leg7
  ),
  grand_total AS (
    SELECT NULLIF(sum(total_seconds), 0) AS total_seconds FROM combined WHERE total_seconds IS NOT NULL
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.ord), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      c.ord,
      c.from_label,
      c.to_label,
      COALESCE(c.n, 0) AS transition_count,
      CASE WHEN c.total_seconds IS NULL THEN NULL ELSE round((c.total_seconds / 3600.0)::numeric, 1) END AS total_hours,
      CASE WHEN c.total_seconds IS NULL OR c.n = 0 THEN NULL ELSE round((c.total_seconds / 3600.0 / c.n)::numeric, 1) END AS avg_hours,
      CASE WHEN c.total_seconds IS NULL OR gt.total_seconds IS NULL THEN NULL
           ELSE round((c.total_seconds / gt.total_seconds * 100)::numeric, 1) END AS pct_of_total
    FROM combined c
    CROSS JOIN grand_total gt
  ) r;

  RETURN v_result;
END;
$function$;
