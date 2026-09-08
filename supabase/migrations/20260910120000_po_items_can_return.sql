-- A Return button on every line with goods received.
--
-- The items table already offers Cancel for a line that never arrived. Its opposite belongs beside
-- it: a line that did arrive can be sent back. Eligibility is decided here rather than in the
-- modal, so the button and process_return_request cannot disagree about what is returnable —
-- goods in hand, and no decision already pending on the item.
--
-- can_cancel gains the same guard: an item already cancelled, returned or mid-request should not
-- offer either action.

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
