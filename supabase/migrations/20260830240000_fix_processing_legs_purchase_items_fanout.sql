-- Fix a real fan-out bug in get_lifecycle_stage_durations legs 2 and 3.
--
-- Both legs joined confirmed_items -> confirmed_orders -> purchase_orders directly on
-- confirmed_order_id. When an order has multiple vendors, it gets multiple purchase_orders rows
-- under the SAME confirmed_order_id — so that join matched every confirmed_item in the order
-- against every PO in the order, not just its own. Verified live: leg 2 was reporting 23 rows for
-- only 14 distinct confirmed_items, and leg 3 was reporting 4 rows for what is really only 2
-- delivered items (each delivered item's order happened to have exactly 2 purchase_orders under
-- it, so each was double-counted).
--
-- The correct link is qvm_new_apps.purchase_items, which ties a confirmed_item to its OWN specific
-- purchase_order_id (not just "some PO in the same order"). Re-verified after the fix: only 10
-- confirmed_items actually have a purchase_items row at all — the other 4 that leg 2 was
-- previously counting had no PO of their own; they were only matched because they shared an order
-- with items that did. Using purchase_items also naturally handles the reverse case (a single
-- confirmed_item legitimately split across 2 real purchase_items rows) by taking the earliest.
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

  -- ---------- Leg 1: Ready For Quotation -> Priced (unchanged) ----------
  leg1 AS (
    SELECT extract(epoch FROM (pl.entered_at - si.created_at)) AS seconds
    FROM (
      SELECT quotation_item_id, min(created_at) AS entered_at
      FROM qvm_new_apps.pricing_logs
      GROUP BY quotation_item_id
    ) pl
    JOIN scoped_items si ON si.quotation_item_id = pl.quotation_item_id
    WHERE pl.entered_at > si.created_at
  ),

  -- ---------- Leg 2: Confirmed -> Processing, via each item's own purchase_items row(s) ----------
  item_po AS (
    SELECT ci.confirmed_item_id, ci.quotation_item_id, ci.confirmed_order_id, min(po.created_at) AS po_created_at
    FROM qvm_new_apps.confirmed_items ci
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.purchase_items pi ON pi.confirmed_item_id = ci.confirmed_item_id
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    GROUP BY ci.confirmed_item_id, ci.quotation_item_id, ci.confirmed_order_id
  ),
  leg2 AS (
    SELECT extract(epoch FROM (ip.po_created_at - co.created_at)) AS seconds
    FROM item_po ip
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ip.confirmed_order_id
    WHERE ip.po_created_at > co.created_at
  ),

  -- ---------- Leg 3: Processing -> Delivered, via the same item-owned PO ----------
  leg3 AS (
    SELECT extract(epoch FROM (dn.created_at - ip.po_created_at)) AS seconds
    FROM item_po ip
    JOIN qvm_new_apps.delivery_notes dn ON dn.confirmed_item_id = ip.confirmed_item_id
    WHERE dn.created_at > ip.po_created_at
  ),

  combined AS (
    SELECT 1 AS ord, 'Ready For Quotation' AS from_label, 'Priced' AS to_label, count(*) AS n, sum(seconds) AS total_seconds
    FROM leg1
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
