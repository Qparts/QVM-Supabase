-- Cancel and return, part 1: the database side.
--
-- Six changes, all serving the purchase-order view modal and the cancel flow around it:
--
--   1. a cancelled item can no longer be sent to a vendor
--   2. cancelling before confirmation reduces the quantity outright — no request, no approval
--   3. the same, from the purchase order, for a line that did not arrive
--   4. a line received in full is Delivered on the quotation, not merely "received"
--   5. receipts get a readable number, PO-<purchase_order_id>-<receipt_id>
--   6. the detail RPC returns the order header, the received and returned quantities, and the
--      cancel and return requests raised against each line
--
-- The modal that consumes 4, 5 and 6 is the next piece of work; the RPC is shaped for it here.

-- 1. A cancelled item cannot be sent to a vendor ------------------------------------------------
-- Checked once, up front, rather than per row inside the loop: sending an RFQ is one action from
-- the user's side, and a partly-sent RFQ that skipped some lines silently would be worse than a
-- refusal that names the problem.

CREATE OR REPLACE FUNCTION qvm_new_apps.assert_items_sendable(p_quotation_items jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT string_agg(DISTINCT COALESCE(qi.part_number, qi.part_description, qi.quotation_item_id::text), ', ')
  FROM jsonb_array_elements(p_quotation_items) e
  JOIN qvm_new_apps.quotation_items qi
    ON qi.quotation_item_id = NULLIF(e->>'quotation_item_id','')::bigint
  WHERE qi.item_status = 18;   -- Canceled
$function$;

-- 2. Cancelling before confirmation --------------------------------------------------------------
-- No request and no approval: until an order is confirmed the client is still composing it, and a
-- line they no longer want is an edit, not something to be reviewed. Cancelling the whole quantity
-- closes the line (18); cancelling part of it just leaves a smaller line.

CREATE OR REPLACE FUNCTION qvm_new_apps.cancel_quotation_item_quantity(
  p_quotation_item_id int,
  p_qty int DEFAULT NULL,          -- NULL or >= quantity cancels the whole line
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
  v_status int;
  v_qty int;
  v_cancel int;
  v_left int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT item_status, COALESCE(quantity, 0) INTO v_status, v_qty
  FROM qvm_new_apps.quotation_items WHERE quotation_item_id = p_quotation_item_id;

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;
  -- 19 is Confirmed. At or past it the item belongs to an order, and cancelling becomes a request
  -- that someone has to approve — process_cancellation_request, not this.
  IF v_status >= 19 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'This item is already confirmed — raise a cancellation request instead');
  END IF;
  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item has no quantity to cancel');
  END IF;

  v_cancel := LEAST(COALESCE(NULLIF(p_qty, 0), v_qty), v_qty);
  IF v_cancel <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cancel quantity must be greater than zero');
  END IF;
  v_left := v_qty - v_cancel;

  UPDATE qvm_new_apps.quotation_items
  SET quantity = GREATEST(v_left, 0),
      item_status = CASE WHEN v_left <= 0 THEN 18 ELSE item_status END,
      cancellation_reason = CASE WHEN v_left <= 0 THEN COALESCE(p_reason_id, cancellation_reason) ELSE cancellation_reason END,
      updated_at = now()
  WHERE quotation_item_id = p_quotation_item_id;

  IF v_left <= 0 THEN
    INSERT INTO qvm_new_apps.status_logs(quotation_item_id, item_status, status_changed_by)
    VALUES (p_quotation_item_id, 18, v_uid);
  END IF;

  INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
  VALUES ('quotation_items', p_quotation_item_id, v_uid, false,
    format('Cancelled %s of %s%s%s', v_cancel, v_qty,
      CASE WHEN p_reason_id IS NULL THEN ''
           ELSE ' — ' || COALESCE((SELECT list_data FROM qvm_new_apps.list_data WHERE list_data_id = p_reason_id), 'reason n/a') END,
      CASE WHEN COALESCE(trim(p_notes),'') = '' THEN '' ELSE ': ' || trim(p_notes) END));

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'cancelled_qty', v_cancel, 'remaining_qty', GREATEST(v_left, 0),
    'fully_cancelled', v_left <= 0));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.cancel_quotation_item_quantity(int, int, int, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_quotation_item_quantity(
  p_quotation_item_id int, p_qty int DEFAULT NULL, p_reason_id int DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.cancel_quotation_item_quantity(p_quotation_item_id, p_qty, p_reason_id, p_notes);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.cancel_quotation_item_quantity(int, int, int, text) TO authenticated;

-- 3. Cancelling a purchase-order line that did not arrive ----------------------------------------
-- Only for lines the warehouse has marked not_received or lower_qty: goods that did arrive are not
-- cancelled, they are returned, which is a different flow with a different paper trail. The
-- cancellable amount is what is still outstanding — ordered, less what came, less what already
-- went back — so a cancel can never erase a receipt.

CREATE OR REPLACE FUNCTION qvm_new_apps.cancel_purchase_item_quantity(
  p_purchase_item_id bigint,
  p_qty int DEFAULT NULL,
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
  v_ordered int;
  v_returned int;
  v_received int;
  v_receipt text;
  v_outstanding int;
  v_cancel int;
  v_client_qty int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT pi.purchase_order_id, pi.confirmed_item_id, COALESCE(pi.approved_qty,0),
         COALESCE(pi.returned_qty,0), pi.receipt_status,
         COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                    WHERE ri.purchase_item_id = pi.purchase_item_id), 0)
    INTO v_po, v_ci, v_ordered, v_returned, v_receipt, v_received
  FROM qvm_new_apps.purchase_items pi
  WHERE pi.purchase_item_id = p_purchase_item_id;

  IF v_po IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase item not found');
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;
  IF COALESCE(v_receipt, 'not_received') NOT IN ('not_received', 'lower_qty') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Only a line marked Not Received or Lower Quantity can be cancelled; a received line is returned instead');
  END IF;

  v_outstanding := GREATEST(v_ordered - v_received - v_returned, 0);
  IF v_outstanding <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nothing outstanding on this line to cancel');
  END IF;

  v_cancel := LEAST(COALESCE(NULLIF(p_qty, 0), v_outstanding), v_outstanding);
  IF v_cancel <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cancel quantity must be greater than zero');
  END IF;

  -- The order shrinks by what was cancelled: the vendor is not sending it and will not be paid for
  -- it. approved_qty is the quantity on order, so that is what moves.
  UPDATE qvm_new_apps.purchase_items
  SET approved_qty = GREATEST(v_ordered - v_cancel, 0),
      vendor_item_status = CASE WHEN v_ordered - v_cancel <= 0 THEN 160 ELSE vendor_item_status END,  -- الغاء
      updated_by = v_uid, updated_at = now()
  WHERE purchase_item_id = p_purchase_item_id;

  -- The client's line shrinks with it, but never below what actually arrived. The two sides can
  -- hold different numbers — the PO carries what was ordered from the vendor, the confirmed item
  -- what the client is owed — so subtracting the PO's outstanding from the client's line can
  -- overshoot. Clamping at v_received is what stops a line with goods in the building being
  -- marked Canceled.
  SELECT GREATEST(COALESCE(ci.approved_qty, 0) - v_cancel, v_received)
    INTO v_client_qty
  FROM qvm_new_apps.confirmed_items ci WHERE ci.confirmed_item_id = v_ci;

  UPDATE qvm_new_apps.confirmed_items
  SET approved_qty = v_client_qty,
      item_status = CASE WHEN v_client_qty <= 0 THEN 18 ELSE item_status END,
      cancellation_reason = COALESCE(p_reason_id, cancellation_reason),
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = v_ci;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  SELECT v_ci, ci.item_status, v_uid
  FROM qvm_new_apps.confirmed_items ci WHERE ci.confirmed_item_id = v_ci;

  INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
  VALUES ('confirmed_items', v_ci, v_uid, false,
    format('Cancelled %s of %s outstanding on PO-%s%s%s', v_cancel, v_outstanding, v_po,
      CASE WHEN p_reason_id IS NULL THEN ''
           ELSE ' — ' || COALESCE((SELECT list_data FROM qvm_new_apps.list_data WHERE list_data_id = p_reason_id), 'reason n/a') END,
      CASE WHEN COALESCE(trim(p_notes),'') = '' THEN '' ELSE ': ' || trim(p_notes) END));

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(v_ci);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'cancelled_qty', v_cancel,
    'outstanding_before', v_outstanding,
    'ordered_now', GREATEST(v_ordered - v_cancel, 0),
    'client_qty_now', v_client_qty,
    'received_kept', v_received,
    'fully_cancelled', v_ordered - v_cancel <= 0));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.cancel_purchase_item_quantity(bigint, int, int, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_purchase_item_quantity(
  p_purchase_item_id bigint, p_qty int DEFAULT NULL, p_reason_id int DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.cancel_purchase_item_quantity(p_purchase_item_id, p_qty, p_reason_id, p_notes);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_item_quantity(bigint, int, int, text) TO authenticated;


-- 4. A line received in full is Delivered on the quotation ---------------------------------------
-- 5. ...and the round carries a readable number, PO-<purchase_order_id>-<receipt_round_id>.

CREATE OR REPLACE FUNCTION qvm_new_apps.save_purchase_receipt_round(p_purchase_order_id bigint, p_items jsonb)
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
  v_delivered int[];
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

  -- A line fully in the warehouse is Delivered on the client's side too. Nothing else moves it:
  -- receiving is the last step that touches the item, so without this it sat at Processing forever.
  -- Only lines that just reached 'received', and only forward — an item already past Delivered
  -- (returned, cancelled) is left where it is.
  WITH promoted AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 23, updated_by = v_uid, updated_at = now()
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.confirmed_item_id = ci.confirmed_item_id
      AND pi.purchase_order_id = p_purchase_order_id
      AND pi.receipt_status = 'received'
      AND ci.item_status IN (19, 21, 22)
    RETURNING ci.confirmed_item_id
  )
  SELECT array_agg(confirmed_item_id) INTO v_delivered FROM promoted;

  IF v_delivered IS NOT NULL THEN
    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    SELECT x, 23, v_uid FROM unnest(v_delivered) x;

    -- Carry it onto the quotation line, which is what every dashboard actually reads.
    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(x) FROM unnest(v_delivered) x;
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'Receipt round saved',
    'data', jsonb_build_object(
      'receipt_round_id', v_round_id,
      'round_no', v_round_no,
      'purchase_order_id', p_purchase_order_id,
      'receipt_number', 'PO-' || p_purchase_order_id || '-' || v_round_id,
      'delivered_items', COALESCE(array_length(v_delivered, 1), 0)));
END;
$function$;


-- 6. The detail RPC the modal reads ---------------------------------------------------------------
-- Adds the header block shown above the items table, the outstanding quantity and whether a line
-- can be cancelled, a readable number on each receipt, and the cancel and return requests raised
-- against the lines on this order.

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
          'requested_qty', COALESCE(ci.approved_qty, 0),
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


-- 1b. Wire the guard into the vendor-quotation creator --------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendors_quotations(p_vendor_selections jsonb, p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_selection           JSONB;
  v_vendor_id           BIGINT;
  v_vendor_branch_id    BIGINT;
  v_quotation_vendor_id BIGINT;
  v_access_token        UUID;
  v_results             JSONB := '[]'::jsonb;
  rec                   JSONB;
  v_item_id             BIGINT;
  v_cost                NUMERIC;
  v_from_database       BOOLEAN;
  v_discount            NUMERIC;
  v_vendor_item_status  INTEGER;
  v_new_cost_id         BIGINT;
BEGIN
  IF p_vendor_selections IS NULL OR jsonb_typeof(p_vendor_selections) <> 'array' OR jsonb_array_length(p_vendor_selections) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_vendor_selections must be a non-empty JSON array');
  END IF;

  IF p_quotation_items IS NULL OR jsonb_typeof(p_quotation_items) <> 'array' OR jsonb_array_length(p_quotation_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_quotation_items must be a non-empty JSON array');
  END IF;

  -- A cancelled line is not something a vendor should be asked to price. Refused as a whole rather
  -- than skipped quietly: sending an RFQ is one action, and silently dropping lines from it would
  -- leave the sender believing they had asked for something they had not.
  DECLARE v_cancelled text;
  BEGIN
    v_cancelled := qvm_new_apps.assert_items_sendable(p_quotation_items);
    IF v_cancelled IS NOT NULL THEN
      RETURN jsonb_build_object('status', false,
        'message', 'Cancelled items cannot be sent to a vendor: ' || v_cancelled);
    END IF;
  END;

  FOR v_selection IN SELECT * FROM jsonb_array_elements(p_vendor_selections) LOOP
    v_vendor_id        := (v_selection->>'vendor_id')::BIGINT;
    v_vendor_branch_id := NULLIF(v_selection->>'vendor_branch_id', '')::BIGINT;

    SELECT quotation_vendor_id, access_token
    INTO v_quotation_vendor_id, v_access_token
    FROM qvm_new_apps.quotation_vendors
    WHERE vendor_id = v_vendor_id
      AND quotation_id = p_quotation_id
      AND vendor_branch_id IS NOT DISTINCT FROM v_vendor_branch_id
    LIMIT 1;

    IF v_quotation_vendor_id IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, vendor_branch_id, quotation_id, created_at)
      VALUES (v_vendor_id, v_vendor_branch_id, p_quotation_id, NOW())
      RETURNING quotation_vendor_id, access_token INTO v_quotation_vendor_id, v_access_token;
    ELSE
      -- Resend: keep the same link working, just push its expiry out another 7 days.
      UPDATE qvm_new_apps.quotation_vendors
      SET token_expires_at = now() + interval '7 days'
      WHERE quotation_vendor_id = v_quotation_vendor_id;
    END IF;

    -- Replace: delete cost_logs that reference the old vendor items first (FK is NO ACTION)
    DELETE FROM qvm_new_apps.cost_logs
    WHERE cost_id IN (
      SELECT cost_id FROM qvm_new_apps.quotation_vendor_items
      WHERE vendor_id = v_vendor_id
        AND quotation_vendor_id = v_quotation_vendor_id
    );

    -- Now delete old items for this vendor so only newly selected items remain
    DELETE FROM qvm_new_apps.quotation_vendor_items
    WHERE vendor_id = v_vendor_id
      AND quotation_vendor_id = v_quotation_vendor_id;

    FOR rec IN SELECT * FROM jsonb_array_elements(p_quotation_items) LOOP
      v_item_id            := (rec->>'quotation_item_id')::BIGINT;
      v_cost               := NULLIF(rec->>'cost','')::NUMERIC;
      v_discount           := NULLIF(rec->>'discount_percent','')::NUMERIC;
      v_from_database      := (rec->>'from_database')::BOOLEAN;
      v_vendor_item_status := (rec->>'vendor_item_status')::INTEGER;

      INSERT INTO qvm_new_apps.quotation_vendor_items (
        quotation_item_id, vendor_id, quotation_vendor_id,
        best_cost, cost, discount_percent, from_database,
        vendor_item_status, created_at, updated_at
      )
      VALUES (
        v_item_id, v_vendor_id, v_quotation_vendor_id,
        FALSE, v_cost, v_discount, v_from_database,
        v_vendor_item_status, NOW(), NOW()
      )
      ON CONFLICT (quotation_item_id, quotation_vendor_id) DO UPDATE
      SET cost = EXCLUDED.cost,
          discount_percent = EXCLUDED.discount_percent,
          from_database = EXCLUDED.from_database,
          vendor_item_status = EXCLUDED.vendor_item_status,
          updated_at = NOW()
      RETURNING cost_id INTO v_new_cost_id;

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'quotation_vendor_id', v_quotation_vendor_id,
          'vendor_id', v_vendor_id,
          'vendor_branch_id', v_vendor_branch_id,
          'access_token', v_access_token,
          'quotation_id', p_quotation_id,
          'quotation_item_id', v_item_id,
          'cost_id', v_new_cost_id,
          'inserted', v_new_cost_id IS NOT NULL
        )
      );

    END LOOP;

  END LOOP;

  -- Update selected quotation items status to "Sent To Vendor" — but never downgrade an item
  -- that's already further along (Priced or beyond): tendering it to one more vendor shouldn't
  -- visually reset its progress.
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  ),
  updated_items AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET item_status = 237,
        updated_at = now()
    FROM sent_items si
    WHERE qi.quotation_item_id = si.quotation_item_id
      AND (qi.item_status IS NULL OR qi.item_status NOT IN (17, 19, 21, 22, 23, 31))
    RETURNING qi.quotation_item_id
  )
  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT quotation_item_id, 237, auth.uid(), now()
  FROM updated_items
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;
$function$;
