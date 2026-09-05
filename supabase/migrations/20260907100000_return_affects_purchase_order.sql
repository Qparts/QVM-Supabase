-- Approved returns reach the purchase order — but only where that is commercially true.
--
-- QVM buys from a vendor and sells to a client, so a client returning a part does not mean the
-- vendor takes it back. return_type (list 12) already distinguishes the three outcomes:
--
--   Exchange (133)           -> the original PO line stands; a replacement is a new line
--   Return to Stock (134)    -> QVM keeps the part; it bought and paid the vendor for it
--   Return to Supplier (135) -> the goods go back and a credit is expected; the PO line reduces
--
-- Only the third touches the vendor side. purchase_items.vendor_item_status (list 15) already
-- carries the vendor return chain and has never been used (every row live is 159 or NULL):
--   166 طلب ارجاع -> 167 تم الارجاع -> 168 تم رفع فاتورة المرتجع -> 169 تم التسوية
-- Approval raises the line to 166 (return requested); the Returns & Exchanges operational flow
-- owns everything after that, so this migration deliberately stops at 166.
--
-- The disposition is chosen by the internal approver, not the client: whether a vendor will take
-- goods back is a QVM-vendor commercial decision, and is usually only known at approval time.
-- process_return_request's p_return_type has never been stored (the client UI passes
-- 'full'/'partial' into it), so nothing is lost by leaving that parameter alone.

-- 1. The disposition ---------------------------------------------------------------------------

ALTER TABLE qvm_new_apps.confirmed_items
  ADD COLUMN IF NOT EXISTS return_type integer REFERENCES qvm_new_apps.list_data(list_data_id);
COMMENT ON COLUMN qvm_new_apps.confirmed_items.return_type IS
  'What happened to the returned goods, chosen by the approver: list 12 — Exchange (133),
   Return to Stock (134), Return to Supplier (135). Only 135 affects the purchase order.';

ALTER TABLE qvm_new_apps.confirmed_item_return_log
  ADD COLUMN IF NOT EXISTS return_type integer,
  ADD COLUMN IF NOT EXISTS purchase_item_id bigint REFERENCES qvm_new_apps.purchase_items(purchase_item_id);
COMMENT ON COLUMN qvm_new_apps.confirmed_item_return_log.purchase_item_id IS
  'The PO line this return was charged back to. Set only for Return to Supplier.';

-- 2. The vendor-side quantity becomes authoritative ---------------------------------------------
-- The receiving dashboard and Vendor Performance both read confirmed_items.approved_qty, the
-- CLIENT-side quantity. Since an approved partial return now shrinks that, a client return was
-- silently moving the vendor side: a PO for 12 with 5 received and 3 returned by the client showed
-- 4 remaining instead of 7, and the vendor's PO value dropped by cost x 3 even though QVM had
-- bought and paid for all 12. purchase_items.approved_qty is the quantity actually ordered from
-- the vendor (set at PO creation by create_purchase_orders_anditems), so it becomes the source of
-- truth in 20260907110000 — but first the rows that predate it need filling in.

ALTER TABLE qvm_new_apps.purchase_items
  ADD COLUMN IF NOT EXISTS returned_qty integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN qvm_new_apps.purchase_items.returned_qty IS
  'Quantity sent back to the vendor. Net quantity on order is approved_qty - returned_qty.';

-- Reconstruct the ordered quantity for older rows: the client-side quantity as it stands plus
-- anything already returned, which is what was ordered before any return shrank it.
UPDATE qvm_new_apps.purchase_items pi
SET approved_qty = GREATEST(COALESCE(ci.approved_qty, 0) + COALESCE(ci.returned_qty, 0), 0)
FROM qvm_new_apps.confirmed_items ci
WHERE ci.confirmed_item_id = pi.confirmed_item_id
  AND pi.approved_qty IS NULL;

-- 3. Approval, with the disposition and the vendor-side effect -----------------------------------
-- The parameter has a default, which would otherwise create a SECOND overload and make the
-- frontend's single-named-argument call ambiguous, so the old one-argument signatures go first.

DROP FUNCTION IF EXISTS qvm_new_apps.approve_item_status_request(int);
DROP FUNCTION IF EXISTS public.approve_item_status_request(integer);

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
  v_to_supplier boolean;
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

    v_to_supplier := (p_return_type = 135);

    -- Charge a Return to Supplier back to the live PO line. A confirmed item can have several
    -- purchase_items (re-ordered from another vendor), so this takes the most recent one that
    -- still has un-returned quantity on it.
    IF v_to_supplier THEN
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
            p_return_type, CASE WHEN v_to_supplier THEN v_pi_id END,
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
      'purchase_item_id', CASE WHEN v_to_supplier THEN v_pi_id END,
      'vendor_side_updated', v_to_supplier AND v_pi_id IS NOT NULL
    ));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.approve_item_status_request(int, int) TO authenticated;

CREATE OR REPLACE FUNCTION public.approve_item_status_request(
  p_confirmed_item_id integer,
  p_return_type integer DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.approve_item_status_request(p_confirmed_item_id, p_return_type);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.approve_item_status_request(integer, integer) TO authenticated;
