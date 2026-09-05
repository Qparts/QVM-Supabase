-- Exchange sends the goods back to the vendor too, so it reduces the PO line.
--
-- 20260907100000 reduced the purchase order only for Return to Supplier (135) and left Exchange
-- (133) alone. That was wrong: an exchange is a swap WITH the vendor — the client returns part A
-- and gets part B, so A comes off the purchase order and B arrives as a new line. Grouping it with
-- Return to Stock meant an approved exchange left the PO showing the full quantity while the
-- client's line had already shrunk.
--
-- Return to Stock (134) stays out, and that is the only exception: QVM keeps the part in its own
-- warehouse and still owes the vendor for it, so reducing the PO there would understate payables.

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
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_row.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;

  -- Cancellation request -> Canceled, unchanged.
  IF v_row.item_status = 24 THEN
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 18, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, 18, v_uid);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', 18));
  END IF;

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
    -- Full return: the line is entirely returned, so it keeps its quantity and reads Returned(29).
    -- Partial: the quantity still with the client shrinks and the line goes back to the status it
    -- held before the request.
    v_remaining  := CASE WHEN v_full THEN v_approved_qty ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 29 ELSE COALESCE(v_row.status_before_request, 23) END;

    -- Exchange (133) and Return to Supplier (135) both physically send the goods back, so both come
    -- off the purchase order. Return to Stock (134) does not: QVM keeps the part and still owes for it.
    v_to_vendor := p_return_type IN (133, 135);

    -- A confirmed item can have several purchase_items (re-ordered from another vendor), so this
    -- takes the most recent one that still has un-returned quantity on it.
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
            updated_by = v_uid,
            updated_at = now()
        WHERE purchase_item_id = v_pi_id;
      END IF;
    END IF;

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

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'full_return', v_full,
      'returned_qty', v_requested_qty,
      'remaining_qty', v_remaining,
      'return_type', p_return_type,
      'purchase_item_id', CASE WHEN v_to_vendor THEN v_pi_id END,
      'vendor_side_updated', v_to_vendor AND v_pi_id IS NOT NULL
    ));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

-- Apply the corrected rule to exchanges already approved under the old one: charge each back to the
-- PO line it should have hit, and record which line that was on its log row.
DO $fix$
DECLARE
  r record;
  v_pi_id bigint;
BEGIN
  FOR r IN
    SELECT l.return_log_id, l.confirmed_item_id, l.returned_qty
    FROM qvm_new_apps.confirmed_item_return_log l
    WHERE l.return_type = 133 AND l.purchase_item_id IS NULL
    ORDER BY l.return_log_id
  LOOP
    SELECT pi.purchase_item_id INTO v_pi_id
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.confirmed_item_id = r.confirmed_item_id
      AND COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0) > 0
    ORDER BY pi.purchase_item_id DESC
    LIMIT 1;

    IF v_pi_id IS NOT NULL THEN
      UPDATE qvm_new_apps.purchase_items
      SET returned_qty = LEAST(COALESCE(returned_qty, 0) + r.returned_qty, COALESCE(approved_qty, 0)),
          vendor_item_status = 166,
          updated_at = now()
      WHERE purchase_item_id = v_pi_id;

      UPDATE qvm_new_apps.confirmed_item_return_log
      SET purchase_item_id = v_pi_id
      WHERE return_log_id = r.return_log_id;

      RAISE NOTICE 'exchange log % (qty %) charged back to purchase_item %', r.return_log_id, r.returned_qty, v_pi_id;
    END IF;
  END LOOP;
END
$fix$;
