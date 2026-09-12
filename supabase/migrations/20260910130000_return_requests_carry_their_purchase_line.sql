-- Return requests raised from the purchase order carry the line they came from.
--
-- The Return button now sits in the PO receipt items table, beside Cancel, so a request is always
-- made against one specific purchase line. Recording which one closes the same hole the
-- cancellation flow had: an item bought on two purchase orders offered the approver no way to tell
-- which vendor the goods go back to, and picking the newest line was a coin toss.
--
-- process_return_request grows the parameter. Because a DEFAULT makes a new overload rather than
-- replacing the old one — and PostgREST then cannot resolve a five-argument call — the previous
-- signature is dropped first, in both schemas.

DROP FUNCTION IF EXISTS public.process_return_request(integer, text, integer, integer, text);
DROP FUNCTION IF EXISTS qvm_new_apps.process_return_request(integer, text, integer, integer, text);

CREATE OR REPLACE FUNCTION qvm_new_apps.process_return_request(
  p_confirmed_item_id integer,
  p_return_type       text,
  p_return_quantity   integer,
  p_return_reason_id  integer,
  p_additional_notes  text   DEFAULT NULL,
  p_purchase_item_id  bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_current_status int;
  v_approved_qty int;
  v_note_id int;
  v_note_text text;
  v_pi_id bigint;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT item_status, COALESCE(approved_qty, 0) INTO v_current_status, v_approved_qty
  FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_current_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;
  IF v_current_status = ANY(ARRAY[19, 24, 28]) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item is not eligible for return yet');
  END IF;
  IF v_current_status = ANY(ARRAY[18, 29]) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item is already cancelled or returned');
  END IF;
  IF p_return_quantity IS NOT NULL AND p_return_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Return quantity must be greater than zero');
  END IF;
  -- Nothing downstream could act on a request for more than the client actually holds.
  IF p_return_quantity IS NOT NULL AND p_return_quantity > v_approved_qty THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('Return quantity %s exceeds the %s on this item', p_return_quantity, v_approved_qty));
  END IF;

  -- Only honour a purchase line that really belongs to this item; a stale id from the caller
  -- would otherwise credit the return against someone else's order.
  IF p_purchase_item_id IS NOT NULL THEN
    SELECT pi.purchase_item_id INTO v_pi_id
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.purchase_item_id = p_purchase_item_id
      AND pi.confirmed_item_id = p_confirmed_item_id;
  END IF;

  v_note_text := COALESCE(p_additional_notes, '');
  IF trim(v_note_text) <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id,
              p_is_internal := false, p_note_description := v_note_text, p_note_attachment := NULL,
              p_kind := 'comment') -> 'data' ->> 'note_id')::int
      INTO v_note_id;
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 28, client_return_reason = p_return_reason_id, requested_return_qty = p_return_quantity,
      status_before_request = v_current_status, pending_request_note_id = v_note_id,
      pending_request_purchase_item_id = v_pi_id,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, 28, v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'confirmed_item_id', p_confirmed_item_id,
    'purchase_item_id', v_pi_id,
    'note_id', v_note_id));
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_return_request(
  p_confirmed_item_id integer,
  p_return_type       text,
  p_return_quantity   integer,
  p_return_reason_id  integer,
  p_additional_notes  text   DEFAULT NULL,
  p_purchase_item_id  bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  RETURN qvm_new_apps.process_return_request(p_confirmed_item_id, p_return_type, p_return_quantity,
                                             p_return_reason_id, p_additional_notes, p_purchase_item_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_return_request(integer, text, integer, integer, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.process_return_request(integer, text, integer, integer, text, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(p_confirmed_item_id integer, p_return_type integer DEFAULT NULL::integer)
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
      -- The line the request was raised from. An item split across two purchase orders has two
      -- candidates, and guessing at the newest sends the wrong vendor a return; falling back to it
      -- only for requests made before this was recorded.
      SELECT pi.purchase_item_id, COALESCE(pi.approved_qty, 0), COALESCE(pi.returned_qty, 0)
        INTO v_pi_id, v_pi_ordered, v_pi_returned
      FROM qvm_new_apps.purchase_items pi
      WHERE pi.confirmed_item_id = p_confirmed_item_id
        AND (v_row.pending_request_purchase_item_id IS NOT NULL
             OR COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0) > 0)
        AND (v_row.pending_request_purchase_item_id IS NULL
             OR pi.purchase_item_id = v_row.pending_request_purchase_item_id)
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
        pending_request_purchase_item_id = NULL,
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
