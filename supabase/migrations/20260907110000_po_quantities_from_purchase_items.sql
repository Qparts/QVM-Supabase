-- Purchase-order quantities come from the purchase order, not from the client's line.
--
-- The receiving RPCs and Vendor Performance all read confirmed_items.approved_qty. That is the
-- CLIENT-side quantity, and since an approved partial return shrinks it, a client return was
-- silently rewriting vendor-side numbers: a PO for 12 with 5 received and 3 returned by the client
-- reported 4 remaining instead of 7 (so QVM stopped expecting 3 units the vendor still owed), and
-- the vendor's PO value fell by cost x 3 although QVM had bought and paid for all 12.
--
-- purchase_items.approved_qty is what was ordered from the vendor (written at PO creation by
-- create_purchase_orders_anditems); 20260907100000 backfilled the rows that predated it and added
-- purchase_items.returned_qty. Net quantity on order is therefore
--   GREATEST(pi.approved_qty - pi.returned_qty, 0)
-- and that is what every RPC below now uses. 20260903120000 moved these reads onto confirmed_items
-- because purchase_items.approved_qty was then only partly populated; that is no longer true.

-- 1. Receiving dashboard ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(
  p_user_id uuid,
  p_is_manager boolean DEFAULT false,
  p_search text DEFAULT NULL,
  p_branch_ids int[] DEFAULT NULL,
  p_supplier_ids int[] DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0,
  p_missing_pi boolean DEFAULT false,
  p_missing_rn boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_result jsonb;
BEGIN
  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  po_agg AS (
    SELECT pi.purchase_order_id,
      count(*)                                                                        AS item_count,
      count(*) FILTER (WHERE pi.receipt_status = 'received')                          AS received_count,
      count(*) FILTER (WHERE pi.receipt_status = 'lower_qty')                         AS lower_qty_count,
      count(*) FILTER (WHERE pi.receipt_status = 'wrong_part')                        AS wrong_part_count,
      count(*) FILTER (WHERE pi.receipt_status IS NULL OR pi.receipt_status = 'not_received') AS not_received_count,
      count(*) FILTER (WHERE COALESCE(pi.returned_qty, 0) > 0)                        AS returned_count,
      sum(GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0))   AS total_approved_qty,
      sum(COALESCE(pi.returned_qty, 0))                                               AS total_returned_qty,
      sum(COALESCE(qvi.cost, 0) * GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)) AS total_value
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE pi.purchase_order_id IS NOT NULL
    GROUP BY pi.purchase_order_id
  ),
  vcn_by_po AS (
    SELECT vcn.purchase_order_id, count(*) AS vcn_count
    FROM qvm_new_apps.vendor_creditnotes vcn GROUP BY vcn.purchase_order_id
  ),
  base AS (
    SELECT
      po.purchase_order_id,
      ('PO-' || po.purchase_order_id) AS po_number,
      q.order_number,
      co.created_at AS confirmation_date,
      vnd.vendor_name,
      po.vendor_id,
      cb.branch_name,
      first_branch.customer_id,
      a.item_count, a.received_count, a.lower_qty_count, a.wrong_part_count, a.not_received_count,
      a.returned_count, a.total_approved_qty, a.total_returned_qty, a.total_value,
      po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url,
      COALESCE(v.vcn_count, 0) AS vcn_count
    FROM qvm_new_apps.purchase_orders po
    JOIN po_agg a ON a.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
    LEFT JOIN vcn_by_po v ON v.purchase_order_id = po.purchase_order_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_branch.customer_id
  ),
  filtered AS (
    SELECT * FROM base b
    WHERE (p_search IS NULL OR p_search = '' OR b.order_number ILIKE '%'||p_search||'%' OR b.vendor_name ILIKE '%'||p_search||'%' OR b.po_number ILIKE '%'||p_search||'%')
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR b.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR b.vendor_id = ANY(v_supplier_ids))
      AND (NOT p_missing_pi OR (
        (coalesce(nullif(trim(b.vendor_invoice_url), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.vendor_invoice_number), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.zoho_bill_url), ''), null) IS NULL)
      ))
      AND (NOT p_missing_rn OR b.vcn_count = 0)
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'total', (SELECT count(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.purchase_order_id DESC) FROM (
        SELECT purchase_order_id, po_number, order_number, confirmation_date, vendor_name, branch_name,
               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               returned_count, total_approved_qty, total_returned_qty, total_value
        FROM filtered ORDER BY purchase_order_id DESC LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- 2. Receiving detail ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_order_receipt_detail(p_purchase_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.can_access_purchase_order(p_purchase_order_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', null);
  END IF;

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'po_number', 'PO-' || po.purchase_order_id,
      'order_number', q.order_number,
      'vendor_name', vnd.vendor_name,

      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'purchase_item_id', pi.purchase_item_id,
          'confirmed_item_id', pi.confirmed_item_id,
          'part_description', qi.part_description,
          'final_part_number', ci.final_part_number,
          'approved_qty', ord.net_qty,
          'ordered_qty', COALESCE(pi.approved_qty, 0),
          'returned_to_vendor_qty', COALESCE(pi.returned_qty, 0),
          'is_returned_to_vendor', COALESCE(pi.returned_qty, 0) > 0,
          'vendor_item_status', pi.vendor_item_status,
          'vendor_item_status_name', (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = pi.vendor_item_status),
          'received_total', rt.received_total,
          'remaining_qty', GREATEST(ord.net_qty - rt.received_total, 0),
          'is_fully_received', (ord.net_qty - rt.received_total) <= 0,
          'receipt_status', pi.receipt_status,
          'received_qty', pi.received_qty,
          'updated_at', pi.receipt_status_updated_at,
          'updated_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = pi.receipt_status_updated_by)
        ) ORDER BY pi.purchase_item_id)
        FROM qvm_new_apps.purchase_items pi
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        CROSS JOIN LATERAL (
          SELECT GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)::int AS net_qty
        ) ord
        CROSS JOIN LATERAL (
          SELECT COALESCE(sum(ri.received_qty), 0)::int AS received_total
          FROM qvm_new_apps.purchase_receipt_round_items ri
          WHERE ri.purchase_item_id = pi.purchase_item_id
        ) rt
        WHERE pi.purchase_order_id = po.purchase_order_id
      ), '[]'::jsonb),

      'rounds', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'receipt_round_id', r.receipt_round_id,
          'round_no', r.round_no,
          'signed_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = r.signed_by),
          'signed_at', r.signed_at,
          'signed_note_at', r.signed_note_at,
          'po_number', r.po_number,
          'items', (
            SELECT jsonb_agg(jsonb_build_object(
              'purchase_item_id', ri.purchase_item_id,
              'receipt_status', ri.receipt_status,
              'received_qty', ri.received_qty
            ) ORDER BY ri.purchase_item_id)
            FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.receipt_round_id = r.receipt_round_id
          ),
          'item_photos', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', f.id, 'file_path', f.file_path, 'created_at', f.created_at))
            FROM qvm_new_apps.files f WHERE f.module_type = 'purchase_receipt_round' AND f.module_id = r.receipt_round_id AND f.field_id = 'item_photos'
          ), '[]'::jsonb),
          'receipt_attachments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', f.id, 'file_path', f.file_path, 'created_at', f.created_at))
            FROM qvm_new_apps.files f WHERE f.module_type = 'purchase_receipt_round' AND f.module_id = r.receipt_round_id AND f.field_id = 'receipt_attachment'
          ), '[]'::jsonb)
        ) ORDER BY r.round_no DESC)
        FROM qvm_new_apps.purchase_receipt_rounds r WHERE r.purchase_order_id = po.purchase_order_id
      ), '[]'::jsonb)
    )
  )
  FROM qvm_new_apps.purchase_orders po
  JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
  WHERE po.purchase_order_id = p_purchase_order_id
  INTO v_result;

  RETURN COALESCE(v_result, jsonb_build_object('status', false, 'message', 'Purchase order not found', 'data', null));
END;
$function$;

-- 3. Saving a receipt round ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.save_purchase_receipt_round(
  p_purchase_order_id bigint,
  p_items jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_round_id bigint;
  v_round_no int;
  v_open_lines int;
  v_bad record;
BEGIN
  IF NOT qvm_new_apps.can_access_purchase_order(p_purchase_order_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'p_items must be a non-empty JSON array');
  END IF;

  -- Everything already received (or returned to the vendor)? Nothing left to receipt.
  SELECT count(*) INTO v_open_lines
  FROM qvm_new_apps.purchase_items pi
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(ri.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.purchase_item_id = pi.purchase_item_id
  ) rt
  WHERE pi.purchase_order_id = p_purchase_order_id
    AND GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0) - rt.received_total > 0;

  IF v_open_lines = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'All items on this purchase order are already fully received');
  END IF;

  -- Reject any lower_qty asking for more than is actually outstanding.
  SELECT pi.purchase_item_id,
         (e->>'received_qty')::int AS asked,
         GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0) - rt.received_total AS remaining
  INTO v_bad
  FROM jsonb_array_elements(p_items) e
  JOIN qvm_new_apps.purchase_items pi ON pi.purchase_item_id = (e->>'purchase_item_id')::bigint
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(ri.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.purchase_item_id = pi.purchase_item_id
  ) rt
  WHERE (e->>'receipt_status') = 'lower_qty'
    AND COALESCE((e->>'received_qty')::int, 0)
        > GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0) - rt.received_total
  LIMIT 1;

  IF v_bad.purchase_item_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('Received quantity %s exceeds the %s remaining on item %s', v_bad.asked, v_bad.remaining, v_bad.purchase_item_id));
  END IF;

  SELECT COALESCE(max(round_no), 0) + 1 INTO v_round_no
  FROM qvm_new_apps.purchase_receipt_rounds WHERE purchase_order_id = p_purchase_order_id;

  INSERT INTO qvm_new_apps.purchase_receipt_rounds (purchase_order_id, round_no, signed_by)
  VALUES (p_purchase_order_id, v_round_no, v_uid)
  RETURNING receipt_round_id INTO v_round_id;

  -- One row per still-open line: 'received' takes the whole remainder, 'lower_qty' the entered
  -- amount, the two problem statuses nothing. Fully-received lines are skipped entirely.
  INSERT INTO qvm_new_apps.purchase_receipt_round_items (receipt_round_id, purchase_item_id, receipt_status, received_qty)
  SELECT
    v_round_id,
    pi.purchase_item_id,
    COALESCE(upd.receipt_status, 'not_received'),
    CASE COALESCE(upd.receipt_status, 'not_received')
      WHEN 'received'  THEN rt.remaining
      WHEN 'lower_qty' THEN LEAST(COALESCE(upd.received_qty, 0), rt.remaining)
      ELSE 0
    END
  FROM qvm_new_apps.purchase_items pi
  CROSS JOIN LATERAL (
    SELECT GREATEST(
      GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0) - COALESCE((
        SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
        WHERE ri.purchase_item_id = pi.purchase_item_id
      ), 0), 0)::int AS remaining
  ) rt
  LEFT JOIN LATERAL (
    SELECT (e->>'receipt_status') AS receipt_status, (e->>'received_qty')::int AS received_qty
    FROM jsonb_array_elements(p_items) e
    WHERE (e->>'purchase_item_id')::bigint = pi.purchase_item_id
    LIMIT 1
  ) upd ON true
  WHERE pi.purchase_order_id = p_purchase_order_id
    AND rt.remaining > 0;

  -- Roll the line's cumulative state up onto purchase_items.
  UPDATE qvm_new_apps.purchase_items pi SET
    received_qty = tot.received_total,
    receipt_status = CASE
      WHEN GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0) > 0
       AND tot.received_total >= GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)
      THEN 'received'
      ELSE ri.receipt_status
    END,
    receipt_status_updated_at = now(),
    receipt_status_updated_by = v_uid
  FROM qvm_new_apps.purchase_receipt_round_items ri
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(r2.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items r2 WHERE r2.purchase_item_id = ri.purchase_item_id
  ) tot
  WHERE ri.receipt_round_id = v_round_id AND ri.purchase_item_id = pi.purchase_item_id;

  RETURN jsonb_build_object('success', true, 'message', 'Receipt round saved',
    'data', jsonb_build_object('receipt_round_id', v_round_id, 'round_no', v_round_no, 'purchase_order_id', p_purchase_order_id));
END;
$function$;

-- 4. Vendor Performance PO value ----------------------------------------------------------------
-- confirmed_value multiplied vendor cost by the CLIENT-side quantity, so a client return reduced
-- the vendor's PO value even when the goods never went back. Now vendor-side and net of returns
-- to the supplier, which is what QVM actually owes that vendor.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_performance_report(p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.received_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendors qv
        WHERE qv.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR qv.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi
            WHERE qi.quotation_id = qv.quotation_id AND qi.customer_id = p_branch_id
          ))
      ) AS received_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qv.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR qv.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi
            WHERE qi.quotation_id = qv.quotation_id AND qi.customer_id = p_branch_id
          ))
      ) AS received_items,
      (
        SELECT count(DISTINCT qvi.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv2 ON qv2.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qvi.vendor_id = v.vendor_id
          AND qvi.cost IS NOT NULL AND qvi.cost > 0
          AND (p_date_from IS NULL OR qv2.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv2.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = qv2.quotation_id AND qi2.customer_id = p_branch_id
          ))
      ) AS priced_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv2 ON qv2.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qvi.vendor_id = v.vendor_id
          AND qvi.cost IS NOT NULL AND qvi.cost > 0
          AND (p_date_from IS NULL OR qv2.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv2.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = qv2.quotation_id AND qi2.customer_id = p_branch_id
          ))
      ) AS priced_items,
      (
        SELECT count(*)
        FROM qvm_new_apps.purchase_orders po
        WHERE po.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci
            JOIN qvm_new_apps.quotation_items qi3 ON qi3.quotation_item_id = ci.quotation_item_id
            WHERE ci.confirmed_order_id = po.confirmed_order_id AND qi3.customer_id = p_branch_id
          ))
      ) AS confirmed_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.purchase_items pi
        JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
        WHERE po.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci2
            JOIN qvm_new_apps.quotation_items qi3b ON qi3b.quotation_item_id = ci2.quotation_item_id
            WHERE ci2.confirmed_order_id = po.confirmed_order_id AND qi3b.customer_id = p_branch_id
          ))
      ) AS confirmed_items,
      (
        SELECT COALESCE(sum(COALESCE(qvi5v.cost, 0) * GREATEST(COALESCE(pi5v.approved_qty, 0) - COALESCE(pi5v.returned_qty, 0), 0)), 0)
        FROM qvm_new_apps.purchase_items pi5v
        JOIN qvm_new_apps.purchase_orders po5v ON po5v.purchase_order_id = pi5v.purchase_order_id
        JOIN qvm_new_apps.confirmed_items ci5v ON ci5v.confirmed_item_id = pi5v.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi5v ON qi5v.quotation_item_id = ci5v.quotation_item_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi5v ON qvi5v.cost_id = qi5v.cost_id
        WHERE po5v.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po5v.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po5v.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci5vb
            JOIN qvm_new_apps.quotation_items qi5vb ON qi5vb.quotation_item_id = ci5vb.quotation_item_id
            WHERE ci5vb.confirmed_order_id = po5v.confirmed_order_id AND qi5vb.customer_id = p_branch_id
          ))
      ) AS confirmed_value,
      (
        SELECT count(DISTINCT qi4.quotation_id)
        FROM qvm_new_apps.quotation_items qi4
        JOIN qvm_new_apps.quotation_vendor_items qvi4 ON qvi4.cost_id = qi4.cost_id
        JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = qi4.quotation_id
        WHERE qvi4.vendor_id = v.vendor_id
          AND qi4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR q4.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q4.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi4.customer_id = p_branch_id)
      ) AS delivered_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_items qi4
        JOIN qvm_new_apps.quotation_vendor_items qvi4 ON qvi4.cost_id = qi4.cost_id
        JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = qi4.quotation_id
        WHERE qvi4.vendor_id = v.vendor_id
          AND qi4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR q4.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q4.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi4.customer_id = p_branch_id)
      ) AS delivered_items,
      (
        SELECT count(DISTINCT qvi5.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi5
        JOIN qvm_new_apps.quotation_vendors qv5 ON qv5.quotation_vendor_id = qvi5.quotation_vendor_id
        WHERE qvi5.vendor_id = v.vendor_id
          AND qvi5.vendor_item_status = 161
          AND (p_date_from IS NULL OR qv5.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv5.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi5
            WHERE qi5.quotation_id = qv5.quotation_id AND qi5.customer_id = p_branch_id
          ))
      ) AS unavailable_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi5
        JOIN qvm_new_apps.quotation_vendors qv5 ON qv5.quotation_vendor_id = qvi5.quotation_vendor_id
        WHERE qvi5.vendor_id = v.vendor_id
          AND qvi5.vendor_item_status = 161
          AND (p_date_from IS NULL OR qv5.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv5.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi5
            WHERE qi5.quotation_id = qv5.quotation_id AND qi5.customer_id = p_branch_id
          ))
      ) AS unavailable_items
    FROM qvm_new_apps.vendors v
  ) r;

  RETURN v_result;
END;
$function$;
