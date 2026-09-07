-- Cancelling from a purchase order is a request, not an edit.
--
-- The previous migration let the warehouse cancel a line outright. That was wrong: a cancellation
-- has to appear on Returns & Exchanges, be approved there, and only then move any quantity — the
-- same route a return takes. This replaces the direct action with a request, and teaches the
-- approval step to cancel a part of a line rather than all of it.
--
-- Pre-confirmation cancelling is untouched and stays immediate: before an order is confirmed the
-- client is still composing it, and there is nothing to approve.

-- A cancellation can now be for part of a line, so it needs its own quantity — the mirror of
-- requested_return_qty, which the return flow has had all along.
ALTER TABLE qvm_new_apps.confirmed_items
  ADD COLUMN IF NOT EXISTS requested_cancel_qty integer,
  ADD COLUMN IF NOT EXISTS pending_request_purchase_item_id bigint
    REFERENCES qvm_new_apps.purchase_items(purchase_item_id);
COMMENT ON COLUMN qvm_new_apps.confirmed_items.pending_request_purchase_item_id IS
  'The purchase-order line a pending cancellation was raised from. An item can sit on more than one
   purchase line — re-ordered from a second vendor — so approval has to act on the line the request
   actually came from rather than guessing at the newest.';
COMMENT ON COLUMN qvm_new_apps.confirmed_items.requested_cancel_qty IS
  'Quantity a pending cancellation request asks to cancel. NULL means the whole line. Cleared when
   the request is decided.';

-- The direct cancel is gone: everything now goes through the request.
DROP FUNCTION IF EXISTS qvm_new_apps.cancel_purchase_item_quantity(bigint, int, int, text);
DROP FUNCTION IF EXISTS public.cancel_purchase_item_quantity(bigint, int, int, text);

-- 1. Raising the request from the purchase order -------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.request_purchase_item_cancellation(
  p_purchase_item_id bigint,
  p_qty int DEFAULT NULL,           -- NULL asks to cancel everything outstanding
  p_reason_id int DEFAULT NULL,
  p_notes text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_po bigint;
  v_ci int;
  v_status int;
  v_ordered int;
  v_returned int;
  v_received int;
  v_receipt text;
  v_outstanding int;
  v_qty int;
  v_note_id int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT pi.purchase_order_id, pi.confirmed_item_id, ci.item_status,
         COALESCE(pi.approved_qty,0), COALESCE(pi.returned_qty,0), pi.receipt_status,
         COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                    WHERE ri.purchase_item_id = pi.purchase_item_id), 0)
    INTO v_po, v_ci, v_status, v_ordered, v_returned, v_receipt, v_received
  FROM qvm_new_apps.purchase_items pi
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  WHERE pi.purchase_item_id = p_purchase_item_id;

  IF v_po IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase item not found');
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;
  -- One open request at a time, or approving it would act on a moving target.
  IF v_status IN (24, 28) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This item already has a request awaiting a decision');
  END IF;
  IF v_status = 18 THEN
    RETURN jsonb_build_object('success', false, 'error', 'This item is already cancelled');
  END IF;
  IF COALESCE(v_receipt, 'not_received') NOT IN ('not_received', 'lower_qty') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Only a line marked Not Received or Lower Quantity can be cancelled; a received line is returned instead');
  END IF;

  v_outstanding := GREATEST(v_ordered - v_received - v_returned, 0);
  IF v_outstanding <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nothing outstanding on this line to cancel');
  END IF;

  v_qty := LEAST(COALESCE(NULLIF(p_qty, 0), v_outstanding), v_outstanding);
  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cancel quantity must be greater than zero');
  END IF;

  IF COALESCE(trim(p_notes), '') <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := v_ci,
              p_is_internal := false, p_note_description := trim(p_notes),
              p_note_attachment := NULL, p_kind := 'comment') -> 'data' ->> 'note_id')::int
      INTO v_note_id;
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 24,
      cancellation_reason = p_reason_id,
      requested_cancel_qty = v_qty,
      pending_request_purchase_item_id = p_purchase_item_id,
      status_before_request = v_status,
      pending_request_note_id = v_note_id,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = v_ci;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (v_ci, 24, v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(v_ci);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'confirmed_item_id', v_ci, 'requested_qty', v_qty, 'outstanding', v_outstanding));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.request_purchase_item_cancellation(bigint, int, int, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.request_purchase_item_cancellation(
  p_purchase_item_id bigint, p_qty int DEFAULT NULL, p_reason_id int DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.request_purchase_item_cancellation(p_purchase_item_id, p_qty, p_reason_id, p_notes);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.request_purchase_item_cancellation(bigint, int, int, text) TO authenticated;

-- 2. Approving a cancellation, in part or in full ------------------------------------------------
-- The cancellation branch used to flip the whole line to Canceled. It now honours the requested
-- quantity: a full cancellation still closes the line, a partial one shrinks it and puts it back
-- where it was, and the purchase order shrinks with it so the vendor is not owed for goods nobody
-- is waiting for any more.

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(
  p_confirmed_item_id int,
  p_return_type int DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row qvm_new_apps.confirmed_items%ROWTYPE;
  v_approved_qty int;
  v_requested_qty int;
  v_remaining int;
  v_full boolean;
  v_new_status int;
  v_to_vendor boolean;
  v_pi_id bigint;
  v_pi_returned int;
  v_pi_ordered int;
  v_case_id bigint;
  v_received int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_row.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;

  ---------------------------------------------------------------------------- cancellation
  IF v_row.item_status = 24 THEN
    v_approved_qty  := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := LEAST(COALESCE(NULLIF(v_row.requested_cancel_qty, 0), v_approved_qty), v_approved_qty);
    v_full := v_requested_qty >= v_approved_qty OR v_approved_qty = 0;
    v_remaining := CASE WHEN v_full THEN 0 ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 18 ELSE COALESCE(v_row.status_before_request, 19) END;

    -- Take it off the purchase order too — the line the request was raised from, falling back to
    -- the newest for a request made before that was recorded. Never below what already arrived.
    SELECT pi.purchase_item_id, COALESCE(pi.approved_qty,0),
           COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                      WHERE ri.purchase_item_id = pi.purchase_item_id), 0)
      INTO v_pi_id, v_pi_ordered, v_received
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.confirmed_item_id = p_confirmed_item_id
      AND (v_row.pending_request_purchase_item_id IS NULL
           OR pi.purchase_item_id = v_row.pending_request_purchase_item_id)
    ORDER BY pi.purchase_item_id DESC
    LIMIT 1;

    IF v_pi_id IS NOT NULL THEN
      UPDATE qvm_new_apps.purchase_items
      SET approved_qty = GREATEST(v_pi_ordered - v_requested_qty, v_received),
          vendor_item_status = CASE WHEN GREATEST(v_pi_ordered - v_requested_qty, v_received) <= 0
                                    THEN 160 ELSE vendor_item_status END,   -- الغاء
          updated_by = v_uid, updated_at = now()
      WHERE purchase_item_id = v_pi_id;
    END IF;

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty            = CASE WHEN v_full THEN approved_qty ELSE v_remaining END,
        item_status             = v_new_status,
        requested_cancel_qty    = NULL,
        pending_request_purchase_item_id = NULL,
        status_before_request   = NULL,
        pending_request_note_id = NULL,
        updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, v_new_status, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'cancelled_qty', v_requested_qty,
      'remaining_qty', CASE WHEN v_full THEN 0 ELSE v_remaining END,
      'full_cancellation', v_full));
  END IF;

  ---------------------------------------------------------------------------- return
  IF v_row.item_status = 28 THEN
    IF p_return_type IS NOT NULL AND p_return_type NOT IN (133, 134, 135) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invalid return type');
    END IF;

    v_approved_qty  := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := LEAST(COALESCE(v_row.requested_return_qty, v_approved_qty), v_approved_qty);

    IF v_requested_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Return quantity must be greater than zero');
    END IF;

    v_full := v_requested_qty >= v_approved_qty;
    v_remaining  := CASE WHEN v_full THEN v_approved_qty ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 29 ELSE COALESCE(v_row.status_before_request, 23) END;

    -- Exchange (133) and Return to Supplier (135) both send the goods back, so both come off the
    -- purchase order. Return to Stock (134) does not: QVM keeps the part and still owes for it.
    v_to_vendor := p_return_type IN (133, 135);

    IF v_to_vendor THEN
      SELECT pi.purchase_item_id, COALESCE(pi.approved_qty, 0), COALESCE(pi.returned_qty, 0)
        INTO v_pi_id, v_pi_ordered, v_pi_returned
      FROM qvm_new_apps.purchase_items pi
      WHERE pi.confirmed_item_id = p_confirmed_item_id
        AND COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0) > 0
      ORDER BY pi.purchase_item_id DESC
      LIMIT 1;

      IF v_pi_id IS NOT NULL THEN
        UPDATE qvm_new_apps.purchase_items
        SET returned_qty = LEAST(v_pi_returned + v_requested_qty, v_pi_ordered),
            vendor_item_status = 166,  -- طلب ارجاع
            updated_by = v_uid, updated_at = now()
        WHERE purchase_item_id = v_pi_id;
      END IF;
    END IF;

    INSERT INTO qvm_new_apps.returned_issues (
      confirmed_item_id, confirmed_order_id, status, return_type, return_reason, created_by, updated_by
    ) VALUES (
      p_confirmed_item_id, v_row.confirmed_order_id, 29, p_return_type, v_row.client_return_reason, v_uid, v_uid
    )
    ON CONFLICT (confirmed_item_id, confirmed_order_id) DO UPDATE SET
      status        = 29,
      return_type   = COALESCE(EXCLUDED.return_type, qvm_new_apps.returned_issues.return_type),
      return_reason = COALESCE(EXCLUDED.return_reason, qvm_new_apps.returned_issues.return_reason),
      updated_by    = EXCLUDED.updated_by,
      updated_at    = now()
    RETURNING returned_issue_id INTO v_case_id;

    INSERT INTO qvm_new_apps.confirmed_item_return_log
      (confirmed_item_id, returned_qty, remaining_qty, is_full_return, return_reason, return_type,
       purchase_item_id, note_id, approved_by, approved_at)
    VALUES (p_confirmed_item_id, v_requested_qty, v_remaining, v_full, v_row.client_return_reason,
            p_return_type, CASE WHEN v_to_vendor THEN v_pi_id END,
            v_row.pending_request_note_id, v_uid, now());

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty            = v_remaining,
        returned_qty            = COALESCE(returned_qty, 0) + v_requested_qty,
        item_status             = v_new_status,
        return_type             = COALESCE(p_return_type, return_type),
        client_return_reason    = CASE WHEN v_full THEN client_return_reason ELSE NULL END,
        requested_return_qty    = NULL,
        status_before_request   = NULL,
        pending_request_note_id = NULL,
        updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, v_new_status, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'full_return', v_full,
      'returned_qty', v_requested_qty,
      'remaining_qty', v_remaining,
      'return_type', p_return_type,
      'purchase_item_id', CASE WHEN v_to_vendor THEN v_pi_id END,
      'vendor_side_updated', v_to_vendor AND v_pi_id IS NOT NULL,
      'returned_issue_id', v_case_id));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

-- 3. Rejecting clears the asked-for quantity too --------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.reject_item_status_request(p_confirmed_item_id int, p_resolution_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_status int;
  v_prev int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT item_status, status_before_request INTO v_status, v_prev
  FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_status IS NULL OR v_status NOT IN (24, 28) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = COALESCE(v_prev, 19), status_before_request = NULL, pending_request_note_id = NULL,
      requested_return_qty = NULL, requested_cancel_qty = NULL,
      pending_request_purchase_item_id = NULL,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, COALESCE(v_prev, 19), v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  IF p_resolution_note IS NOT NULL AND trim(p_resolution_note) <> '' THEN
    PERFORM qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id,
      p_is_internal := false, p_note_description := 'Request rejected: ' || p_resolution_note,
      p_note_attachment := NULL, p_kind := 'comment');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', COALESCE(v_prev, 19)));
END;
$function$;


-- 4. The pending-requests list carries the asked-for quantity for cancellations too ---------------
-- A cancellation used to have no quantity at all, so Returns & Exchanges showed a dash where the
-- return rows showed a number. Both kinds now report through requested_return_qty, with the raw
-- cancel figure alongside for anything that wants to tell them apart.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_pending_item_status_requests(p_request_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_status_id int;
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_status_id := CASE p_request_type WHEN 'cancellation' THEN 24 WHEN 'return' THEN 28 ELSE NULL END;
  IF v_status_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'Invalid request type', 'data', '[]'::jsonb);
  END IF;

  WITH base AS (
    SELECT
      ci.confirmed_item_id,
      q.order_number,
      cb.branch_name,
      qi.part_description,
      ci.final_part_number,
      ci.approved_qty,
      -- The quantity for the kind of request being listed. A COALESCE across both would pick up a
      -- stale figure from the other kind — an item that was once returned still carries its old
      -- requested_return_qty — and report it against a cancellation.
      CASE WHEN v_status_id = 24 THEN ci.requested_cancel_qty ELSE ci.requested_return_qty END
        AS requested_return_qty,
      ci.requested_cancel_qty,
      ld_reason.list_data AS reason_name,
      ci.updated_at AS requested_at,
      (
        SELECT sl.status_changed_by FROM qvm_new_apps.status_logs sl
        WHERE sl.confirmed_item_id = ci.confirmed_item_id AND sl.item_status = v_status_id
        ORDER BY sl.created_at DESC LIMIT 1
      ) AS requested_by,
      (
        SELECT n.note_id FROM qvm_new_apps.notes n
        WHERE n.note_type = 'confirmed_items' AND n.type_id = ci.confirmed_item_id
        ORDER BY n.created_at DESC LIMIT 1
      ) AS note_id,
      (
        SELECT n.note_description FROM qvm_new_apps.notes n
        WHERE n.note_type = 'confirmed_items' AND n.type_id = ci.confirmed_item_id
        ORDER BY n.created_at DESC LIMIT 1
      ) AS note_text
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id =
      (CASE WHEN v_status_id = 24 THEN ci.cancellation_reason ELSE ci.client_return_reason END)
    WHERE ci.item_status = v_status_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.requested_at DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      b.*,
      (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = b.requested_by) AS requested_by_name,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', f.id, 'file_path', f.file_path))
        FROM qvm_new_apps.files f WHERE f.module_type = 'notes' AND f.module_id = b.note_id
      ), '[]'::jsonb) AS attachments
    FROM base b
  ) r;

  RETURN v_result;
END;
$function$;


-- 5. The purchase-order modal shows what a pending cancellation asks for -------------------------

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
                        AND (ord.net_qty - rt.received_total) > 0,
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
