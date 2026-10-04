-- A purchase order tells what came back.
--
-- The receipt detail and the receipt dashboard price a purchase order at the vendor's cost on the
-- quantity that stayed (approved minus returned), VAT included. Nothing told the reader what the
-- returned part was worth, yet that number is the credit note the vendor owes and the default for
-- the credit-note amount when the invoice is filed. Both functions now carry it, priced the same
-- way: `returned_with_vat` on the detail, `total_returned_value` (before VAT, like `total_value`)
-- on each dashboard row.
--
-- The dashboard row also names the vendor branch the order was placed on and that branch's
-- payment term (`credit_term_days`), so the invoice-upload form can show the term the branch was
-- set up with instead of asking for it. An older order that never named a branch takes the
-- vendor's preferred branch, then its first.
--
-- Nothing is removed and no column changes meaning; every new key is additive.

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

      -- Header block above the items table.
      'po_created_at', po.created_at,
      'confirmation_date', co.created_at,
      'branch_name', cb.branch_name,
      'client_name', ld_client.list_data,
      'created_by_name', (SELECT user_name FROM qvm_new_apps.user_data
                           WHERE user_id = COALESCE(po.created_by, po.uploaded_by)),
      'plate_number', q.plate_number,
      'item_count', (SELECT count(*) FROM qvm_new_apps.purchase_items pic
                      WHERE pic.purchase_order_id = po.purchase_order_id),
      'received_item_count', (SELECT count(*) FROM qvm_new_apps.purchase_items pic
                               WHERE pic.purchase_order_id = po.purchase_order_id
                                 AND pic.receipt_status = 'received'),
      'total_with_vat', ROUND(COALESCE((
        SELECT sum(COALESCE(qvi.cost, 0)
                   * GREATEST(COALESCE(pit.approved_qty,0) - COALESCE(pit.returned_qty,0), 0))
        FROM qvm_new_apps.purchase_items pit
        JOIN qvm_new_apps.confirmed_items cit ON cit.confirmed_item_id = pit.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qit ON qit.quotation_item_id = cit.quotation_item_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qit.cost_id
        WHERE pit.purchase_order_id = po.purchase_order_id), 0) * 1.15, 2),
      -- What went back to the vendor, priced the same way: the vendor's cost on the returned
      -- quantity, VAT included. The credit note the vendor owes is this number.
      'returned_with_vat', ROUND(COALESCE((
        SELECT sum(COALESCE(qvi.cost, 0) * COALESCE(pit.returned_qty, 0))
        FROM qvm_new_apps.purchase_items pit
        JOIN qvm_new_apps.confirmed_items cit ON cit.confirmed_item_id = pit.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qit ON qit.quotation_item_id = cit.quotation_item_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qit.cost_id
        WHERE pit.purchase_order_id = po.purchase_order_id), 0) * 1.15, 2),

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
          -- Taken off this purchase line after it was raised — by the vendor, or by an approved
          -- cancellation. A line with nothing left to order and nothing received is cancelled.
          'cancelled_qty', cq.cancelled_qty,
          'is_cancelled', COALESCE(pi.approved_qty, 0) = 0 AND rt.received_total = 0
                          AND (cq.cancelled_qty > 0 OR pi.vendor_item_status = 160 OR ci.item_status = 18),
          'remaining_qty', GREATEST(ord.net_qty - rt.received_total, 0),
          'is_fully_received', (ord.net_qty - rt.received_total) <= 0,
          'receipt_status', pi.receipt_status,
          'received_qty', pi.received_qty,
          -- Cancelling is for goods that never arrived; anything received is returned instead.
          'outstanding_qty', GREATEST(ord.net_qty - rt.received_total, 0),
          'can_cancel', COALESCE(pi.receipt_status, 'not_received') IN ('not_received','lower_qty')
                        AND (ord.net_qty - rt.received_total) > 0
                        AND ci.item_status NOT IN (18, 24, 28, 29),
          -- Returning needs goods actually in hand, and an item not already mid-decision.
          -- 19 is excluded to match process_return_request, which holds a Confirmed item as not
          -- yet returnable — nothing has been delivered to send back.
          'can_return', rt.received_total > 0 AND ci.item_status NOT IN (18, 19, 24, 28, 29),
          -- What the client can actually send back: never more than they hold, and never more
          -- than arrived on this line — historical rounds on dev record more received than
          -- ordered, and a return larger than the order would be nonsense.
          'returnable_qty', LEAST(COALESCE(ci.approved_qty, 0), rt.received_total),
          'item_status', ci.item_status,
          'item_status_name', (SELECT ld.list_data FROM qvm_new_apps.list_data ld
                                WHERE ld.list_data_id = ci.item_status),
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
        CROSS JOIN LATERAL (
          SELECT COALESCE(sum(c.qty), 0)::int AS cancelled_qty
          FROM qvm_new_apps.quotation_item_cancellations c
          WHERE c.purchase_item_id = pi.purchase_item_id
        ) cq
        WHERE pi.purchase_order_id = po.purchase_order_id
      ), '[]'::jsonb),

      'rounds', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'receipt_round_id', r.receipt_round_id,
          'round_no', r.round_no,
          'receipt_number', 'PO-' || po.purchase_order_id || '-' || r.receipt_round_id,
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
      ), '[]'::jsonb),

      -- Cancellation requests raised against the lines on this order. A pending one sits at
      -- status 24; once decided the item reads Canceled(18) if it was approved, or whatever it
      -- went back to if it was not — so the decision is read from the item, not stored twice.
      'cancel_requests', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'confirmed_item_id', ci.confirmed_item_id,
          'part_number', ci.final_part_number,
          'part_description', qi.part_description,
          -- What the request asks to cancel while it is pending; once decided the figure is
          -- gone from the item, so the line's own quantity is what is left to show.
          'requested_qty', COALESCE(ci.requested_cancel_qty, ci.approved_qty, 0),
          'reason', ld_r.list_data,
          'status', CASE WHEN ci.item_status = 24 THEN 'pending'
                         WHEN ci.item_status = 18 THEN 'approved'
                         ELSE 'rejected' END,
          'item_status_name', ld_s.list_data,
          'requested_at', ci.updated_at,
          'note', (SELECT n.note_description FROM qvm_new_apps.notes n
                    WHERE n.note_type = 'confirmed_items' AND n.type_id = ci.confirmed_item_id
                    ORDER BY n.created_at DESC LIMIT 1)
        ) ORDER BY ci.confirmed_item_id)
        FROM qvm_new_apps.purchase_items pic
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pic.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        LEFT JOIN qvm_new_apps.list_data ld_r ON ld_r.list_data_id = ci.cancellation_reason
        LEFT JOIN qvm_new_apps.list_data ld_s ON ld_s.list_data_id = ci.item_status
        WHERE pic.purchase_order_id = po.purchase_order_id
          AND (ci.item_status IN (18, 24) OR ci.cancellation_reason IS NOT NULL)
      ), '[]'::jsonb),

      -- Return requests. Approved ones are rows in confirmed_item_return_log, which records the
      -- quantity and disposition; a pending one is still only a status on the item, so both are
      -- unioned rather than read from one place.
      'return_requests', COALESCE((
        SELECT jsonb_agg(x ORDER BY x->>'requested_at' DESC) FROM (
          SELECT jsonb_build_object(
            'confirmed_item_id', ci.confirmed_item_id,
            'part_number', ci.final_part_number,
            'part_description', qi.part_description,
            'requested_qty', ci.requested_return_qty,
            'reason', (SELECT ld.list_data FROM qvm_new_apps.list_data ld
                        WHERE ld.list_data_id = ci.client_return_reason),
            'return_type', NULL::text,
            'status', 'pending',
            'requested_at', ci.updated_at,
            'approved_by_name', NULL::text
          ) AS x
          FROM qvm_new_apps.purchase_items pic
          JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pic.confirmed_item_id
          LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
          WHERE pic.purchase_order_id = po.purchase_order_id AND ci.item_status = 28

          UNION ALL

          SELECT jsonb_build_object(
            'confirmed_item_id', l.confirmed_item_id,
            'part_number', ci.final_part_number,
            'part_description', qi.part_description,
            'requested_qty', l.returned_qty,
            'reason', (SELECT ld.list_data FROM qvm_new_apps.list_data ld
                        WHERE ld.list_data_id = l.return_reason),
            'return_type', (SELECT ld.list_data FROM qvm_new_apps.list_data ld
                             WHERE ld.list_data_id = l.return_type),
            'status', 'approved',
            'requested_at', l.approved_at,
            'approved_by_name', (SELECT user_name FROM qvm_new_apps.user_data
                                  WHERE user_id = l.approved_by)
          )
          FROM qvm_new_apps.purchase_items pic
          JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pic.confirmed_item_id
          JOIN qvm_new_apps.confirmed_item_return_log l ON l.confirmed_item_id = ci.confirmed_item_id
          LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
          WHERE pic.purchase_order_id = po.purchase_order_id
        ) rq
      ), '[]'::jsonb)
    )
  )
  FROM qvm_new_apps.purchase_orders po
  JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
  LEFT JOIN LATERAL (
    SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
    WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
    ORDER BY qi0.quotation_item_id ASC LIMIT 1
  ) fb ON true
  LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fb.customer_id
  LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
  WHERE po.purchase_order_id = p_purchase_order_id
  INTO v_result;

  RETURN COALESCE(v_result, jsonb_build_object('status', false, 'message', 'Purchase order not found', 'data', null));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false)
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
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
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
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  po_agg AS (
    SELECT pi.purchase_order_id,
      count(*)                                                                        AS item_count,
      count(*) FILTER (WHERE pi.receipt_status = 'received')                          AS received_count,
      count(*) FILTER (WHERE pi.receipt_status = 'lower_qty')                         AS lower_qty_count,
      count(*) FILTER (WHERE pi.receipt_status = 'wrong_part')                        AS wrong_part_count,
      -- A line taken off the order entirely (by the vendor, or by an approved cancellation) is
      -- cancelled, not "not received": there is nothing left to receive.
      count(*) FILTER (WHERE (pi.receipt_status IS NULL OR pi.receipt_status = 'not_received')
                         AND NOT cx.is_cancelled)                                          AS not_received_count,
      count(*) FILTER (WHERE cx.is_cancelled)                                               AS cancelled_count,
      sum(cx.cancelled_qty)                                                                 AS total_cancelled_qty,
      -- Returned to the vendor, or returned by the client and kept in stock (disposition 134,
      -- which never touches the purchase line). Either way the item came back.
      count(*) FILTER (WHERE COALESCE(pi.returned_qty, 0) > 0
                          OR COALESCE(ci.returned_qty, 0) > 0)                        AS returned_count,
      sum(GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0))   AS total_approved_qty,
      sum(COALESCE(pi.returned_qty, 0))                                               AS total_returned_qty,
      sum(COALESCE(qvi.cost, 0) * GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)) AS total_value,
      -- What went back to the vendor, at the vendor's cost: the credit note the vendor owes.
      sum(COALESCE(qvi.cost, 0) * COALESCE(pi.returned_qty, 0))                                             AS total_returned_value
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    CROSS JOIN LATERAL (
      SELECT cq.cancelled_qty,
             (COALESCE(pi.approved_qty, 0) = 0
              AND COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                             WHERE ri.purchase_item_id = pi.purchase_item_id), 0) = 0
              AND (cq.cancelled_qty > 0 OR pi.vendor_item_status = 160 OR ci.item_status = 18)) AS is_cancelled
      FROM (SELECT COALESCE(sum(c.qty), 0)::int AS cancelled_qty
              FROM qvm_new_apps.quotation_item_cancellations c
             WHERE c.purchase_item_id = pi.purchase_item_id) cq
    ) cx
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
      po.created_at AS po_created_at,
      -- The supplier: the purchase order's own vendor, else the vendor of the priced line its items
      -- were bought from — a purchase order raised without vendor_id still names who it went to.
      COALESCE(vnd.vendor_name, lv.vendor_name) AS vendor_name,
      COALESCE(po.vendor_id, lv.vendor_id) AS vendor_id,
      vbr.vendor_branch_id, vbr.credit_term_days,
      cb.branch_name,
      COALESCE(vcc.name, ld_client.list_data) AS client_name,
      first_branch.customer_id,
      -- Falls back to uploaded_by: POs raised through upsert_purchase_order_items record the user
      -- there, and older rows predate the created_by trigger.
      COALESCE(ucb.user_name, uup.user_name) AS created_by_name,
      COALESCE(po.created_by, po.uploaded_by) AS created_by,
      a.item_count, a.received_count, a.lower_qty_count, a.wrong_part_count, a.not_received_count,
      a.cancelled_count, a.total_cancelled_qty,
      a.returned_count, a.total_approved_qty, a.total_returned_qty, a.total_value, a.total_returned_value,
      po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url,
      -- The invoice files filed on this purchase order, or on a holder purchase order of its order.
      inv.pi_attachment_count, inv.first_invoice_url, inv.invoice_numbers,
      COALESCE(v.vcn_count, 0) AS vcn_count
    FROM qvm_new_apps.purchase_orders po
    JOIN po_agg a ON a.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
    LEFT JOIN qvm_new_apps.user_data ucb ON ucb.user_id = po.created_by
    LEFT JOIN qvm_new_apps.user_data uup ON uup.user_id = po.uploaded_by
    LEFT JOIN vcn_by_po v ON v.purchase_order_id = po.purchase_order_id
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS pi_attachment_count,
             (array_agg(a.file_url ORDER BY a.uploaded_at DESC))[1] AS first_invoice_url,
             string_agg(DISTINCT NULLIF(btrim(a.invoice_number), ''), ', ') AS invoice_numbers
        FROM qvm_new_apps.purchase_invoice_attachments a
       WHERE a.cancelled_at IS NULL
         -- Filed on this purchase order, on a holder purchase order of the order (no items), or on
         -- another purchase order of the order that carries the same items — an invoice for the goods
         -- belongs to every purchase order those goods sit on.
         AND (a.purchase_order_id = po.purchase_order_id
                  OR (a.confirmed_order_id = po.confirmed_order_id
                      AND (NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items hx WHERE hx.purchase_order_id = a.purchase_order_id)
                           OR EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items x
                                       JOIN qvm_new_apps.purchase_items y ON y.confirmed_item_id = x.confirmed_item_id
                                      WHERE x.purchase_order_id = a.purchase_order_id AND y.purchase_order_id = po.purchase_order_id))))
    ) inv ON true
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_branch.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.v_client_companies vcc ON vcc.company_id = cb.list_data_id
    LEFT JOIN LATERAL (
      SELECT v2.vendor_id, v2.vendor_name
        FROM qvm_new_apps.purchase_items pi2
        JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = pi2.confirmed_item_id
        JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi2 ON qvi2.cost_id = COALESCE(pi2.cost_id, qi2.selected_cost_id, qi2.cost_id)
        JOIN qvm_new_apps.vendors v2 ON v2.vendor_id = qvi2.vendor_id
       WHERE pi2.purchase_order_id = po.purchase_order_id
       ORDER BY pi2.purchase_item_id
       LIMIT 1
    ) lv ON true
    -- The vendor branch the order was placed on; an older order that never named one takes the
    -- vendor's preferred branch, then its first. Its payment term is the invoice's payment term.
    LEFT JOIN LATERAL (
      SELECT vb.vendor_branch_id, vb.credit_term_days
        FROM qvm_new_apps.vendor_branches vb
       WHERE vb.vendor_branch_id = po.vendor_branch_id
          OR (po.vendor_branch_id IS NULL AND vb.vendor_id = COALESCE(po.vendor_id, lv.vendor_id))
       ORDER BY (vb.vendor_branch_id = po.vendor_branch_id) DESC NULLS LAST,
                (vb.vendor_branch_id = vnd.preferred_branch_id) DESC NULLS LAST,
                vb.is_active DESC NULLS LAST, vb.vendor_branch_id
       LIMIT 1
    ) vbr ON true
  ),
  filtered AS (
    SELECT * FROM base b
    WHERE (p_search IS NULL OR p_search = '' OR b.order_number ILIKE '%'||p_search||'%' OR b.vendor_name ILIKE '%'||p_search||'%' OR b.po_number ILIKE '%'||p_search||'%'
           OR b.created_by_name ILIKE '%'||p_search||'%')
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR b.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR b.vendor_id = ANY(v_supplier_ids))
      AND (NOT p_missing_pi OR (
        (coalesce(nullif(trim(b.vendor_invoice_url), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.vendor_invoice_number), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.zoho_bill_url), ''), null) IS NULL)
        AND COALESCE(b.pi_attachment_count, 0) = 0
      ))
      AND (NOT p_missing_rn OR b.vcn_count = 0)
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'total', (SELECT count(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.purchase_order_id DESC) FROM (
        SELECT purchase_order_id, po_number, order_number, confirmation_date, po_created_at,
               vendor_name, vendor_id, vendor_branch_id, credit_term_days,
               branch_name, client_name, created_by, created_by_name,
               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               cancelled_count, total_cancelled_qty,
               returned_count, total_approved_qty, total_returned_qty, total_value, total_returned_value,
               vendor_invoice_url, vendor_invoice_number, zoho_bill_url, vcn_count,
               pi_attachment_count, first_invoice_url, invoice_numbers
        FROM filtered ORDER BY purchase_order_id DESC LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;
