-- A cancelled quantity can be bought again.
--
-- Until now a quantity cancelled after confirmation simply left: the vendor had no way to give a
-- purchase line back at all, and an approved cancellation shrank the confirmed line, the purchase
-- line and the quotation line alike, leaving nothing that said the customer still wanted the part.
--
-- Now: the vendor can cancel what is still outstanding on a purchase line from their dashboard
-- (vendor_cancel_purchase_item); every cancellation — the vendor's or an approved request's — is
-- recorded in quotation_item_cancellations; the pricing page shows it on the line and lets the desk
-- put the quantity back on the order as a new line (reissue_cancelled_quantity), either confirmed
-- on another vendor who priced the line or sent to vendors again. A re-issued line names its
-- parent (quotation_items.reissued_from_item_id) and stands on the parent's approvals.
ALTER TABLE qvm_new_apps.quotation_items ADD COLUMN IF NOT EXISTS reissued_from_item_id bigint;
CREATE INDEX IF NOT EXISTS ix_quotation_items_reissued_from
  ON qvm_new_apps.quotation_items (reissued_from_item_id) WHERE reissued_from_item_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS qvm_new_apps.quotation_item_cancellations (
  cancellation_id   bigserial PRIMARY KEY,
  quotation_item_id integer NOT NULL,
  confirmed_item_id integer,
  purchase_item_id  bigint,
  vendor_id         integer,                       -- whose purchase line lost the quantity
  qty               integer NOT NULL CHECK (qty > 0),
  source            text NOT NULL CHECK (source IN ('vendor', 'workshop', 'qparts')),
  reason_id         integer,
  note              text,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  reissued_item_id  bigint,                        -- the new line, once the desk put the quantity back
  reissued_at       timestamptz,
  reissued_by       uuid
);
CREATE INDEX IF NOT EXISTS ix_quotation_item_cancellations_item ON qvm_new_apps.quotation_item_cancellations (quotation_item_id);
GRANT SELECT ON qvm_new_apps.quotation_item_cancellations TO authenticated, service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.quotation_item_cancellations_cancellation_id_seq TO authenticated, service_role;


-- The vendor gives back part of a purchase order: the quantity comes off the PO and the confirmed
-- line at once (no request, no approval — it is their own supply), and is recorded as cancelled by
-- them so the desk can buy it elsewhere.
CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_cancel_purchase_item(p_purchase_item_id bigint, p_qty integer DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_vendor int; v_utype int; v_vendor_name text;
  v_po bigint; v_po_vendor int; v_ci int; v_qi int; v_status int;
  v_ordered int; v_returned int; v_received int; v_receipt text; v_ci_qty int;
  v_outstanding int; v_qty int; v_pi_left int; v_left int;
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT ud.user_vendor, ud.user_type INTO v_vendor, v_utype FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid;
  IF v_vendor IS NULL OR v_utype <> 205 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only vendor users can cancel a purchase line');
  END IF;

  SELECT pi.purchase_order_id, po.vendor_id, pi.confirmed_item_id, ci.quotation_item_id, ci.item_status,
         COALESCE(pi.approved_qty, 0), COALESCE(pi.returned_qty, 0), pi.receipt_status,
         COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                    WHERE ri.purchase_item_id = pi.purchase_item_id), 0),
         COALESCE(ci.approved_qty, 0)
    INTO v_po, v_po_vendor, v_ci, v_qi, v_status, v_ordered, v_returned, v_receipt, v_received, v_ci_qty
  FROM qvm_new_apps.purchase_items pi
  JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  WHERE pi.purchase_item_id = p_purchase_item_id;

  IF v_po IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase line not found');
  END IF;
  IF v_po_vendor IS DISTINCT FROM v_vendor THEN
    RETURN jsonb_build_object('success', false, 'error', 'This purchase order belongs to another vendor');
  END IF;
  IF v_status IN (24, 28) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This line has a request awaiting a decision');
  END IF;
  IF v_status IN (18, 29) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This line is already closed');
  END IF;
  IF COALESCE(v_receipt, 'not_received') NOT IN ('not_received', 'lower_qty') THEN
    RETURN jsonb_build_object('success', false, 'error', 'A line already received cannot be cancelled');
  END IF;

  v_outstanding := GREATEST(v_ordered - v_received - v_returned, 0);
  IF v_outstanding <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nothing outstanding on this line to cancel');
  END IF;
  v_qty := LEAST(COALESCE(NULLIF(p_qty, 0), v_outstanding), v_outstanding);
  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cancel quantity must be greater than zero');
  END IF;

  -- Off the purchase order. Never below what already arrived.
  v_pi_left := GREATEST(v_ordered - v_qty, v_received);
  UPDATE qvm_new_apps.purchase_items
     SET approved_qty = v_pi_left,
         vendor_item_status = CASE WHEN v_pi_left <= 0 THEN 160 ELSE vendor_item_status END,   -- الغاء
         updated_by = v_uid, updated_at = now()
   WHERE purchase_item_id = p_purchase_item_id;

  -- Off the confirmed line, the way an approved cancellation takes it off: a partial keeps the line
  -- with the smaller quantity, a full one closes it as Canceled.
  v_left := GREATEST(v_ci_qty - v_qty, 0);
  UPDATE qvm_new_apps.confirmed_items
     SET approved_qty = CASE WHEN v_left <= 0 THEN approved_qty ELSE v_left END,
         item_status  = CASE WHEN v_left <= 0 THEN 18 ELSE item_status END,
         updated_by = v_uid, updated_at = now()
   WHERE confirmed_item_id = v_ci;
  IF v_left <= 0 THEN
    INSERT INTO qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by) VALUES (v_ci, 18, v_uid);
  END IF;
  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(v_ci);

  SELECT vendor_name INTO v_vendor_name FROM qvm_new_apps.vendors WHERE vendor_id = v_vendor;

  INSERT INTO qvm_new_apps.quotation_item_cancellations
    (quotation_item_id, confirmed_item_id, purchase_item_id, vendor_id, qty, source, note, created_by)
  VALUES (v_qi, v_ci, p_purchase_item_id, v_vendor, v_qty, 'vendor', v_note, v_uid);

  INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
  VALUES ('confirmed_items', v_ci, v_uid, false,
          format('%s cancelled %s of %s from PO-%s%s', COALESCE(v_vendor_name, 'The vendor'), v_qty, v_ordered, v_po,
                 CASE WHEN v_note IS NULL THEN '' ELSE ': ' || v_note END));

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'cancelled_qty', v_qty, 'left_on_po', v_pi_left, 'line_status', CASE WHEN v_left <= 0 THEN 18 ELSE v_status END));
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.vendor_cancel_purchase_item(bigint, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.vendor_cancel_purchase_item(bigint, integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.vendor_cancel_purchase_item(p_purchase_item_id bigint, p_qty integer DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT qvm_new_apps.vendor_cancel_purchase_item(p_purchase_item_id, p_qty, p_note);
$function$;
GRANT EXECUTE ON FUNCTION public.vendor_cancel_purchase_item(bigint, integer, text) TO authenticated;

-- The desk puts a cancelled quantity back on the order as a line of its own — the one line per
-- confirmed item the schema allows is already taken by the original. With a vendor's offer
-- (p_cost_id, one of the parent line's prices) the new line is confirmed on that vendor at once,
-- and every other vendor's price on the parent comes along so the pick can still change; without
-- one it is Ready For Quotation, to be sent to vendors again.
CREATE OR REPLACE FUNCTION qvm_new_apps.reissue_cancelled_quantity(p_cancellation_id bigint, p_cost_id bigint DEFAULT NULL, p_quantity integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  c     qvm_new_apps.quotation_item_cancellations%ROWTYPE;
  p     qvm_new_apps.quotation_items%ROWTYPE;
  v_ci  qvm_new_apps.confirmed_items%ROWTYPE;
  v_src qvm_new_apps.quotation_vendor_items%ROWTYPE;
  v_qty int; v_child bigint; v_status int; v_code text;
  v_sel bigint; v_cp bigint; v_order bigint; v_new_ci bigint; v_vendor_name text;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Internal users only');
  END IF;

  SELECT * INTO c FROM qvm_new_apps.quotation_item_cancellations WHERE cancellation_id = p_cancellation_id FOR UPDATE;
  IF c.cancellation_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'Cancellation not found');
  END IF;
  IF c.reissued_item_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'This quantity is already back on the order');
  END IF;
  v_qty := LEAST(GREATEST(COALESCE(p_quantity, c.qty), 1), c.qty);

  SELECT * INTO p FROM qvm_new_apps.quotation_items WHERE quotation_item_id = c.quotation_item_id;
  SELECT * INTO v_ci FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = c.confirmed_item_id;

  IF p_cost_id IS NOT NULL THEN
    SELECT * INTO v_src FROM qvm_new_apps.quotation_vendor_items WHERE cost_id = p_cost_id AND quotation_item_id = c.quotation_item_id;
    IF v_src.cost_id IS NULL OR COALESCE(v_src.cost, 0) <= 0 THEN
      RETURN jsonb_build_object('status', false, 'message', 'Pick one of the vendors who priced this line');
    END IF;
    IF c.vendor_id IS NOT NULL AND v_src.vendor_id = c.vendor_id THEN
      RETURN jsonb_build_object('status', false, 'message', 'That is the vendor who cancelled — pick another, or send the line again');
    END IF;
  END IF;

  v_status := CASE WHEN p_cost_id IS NULL THEN 235 ELSE 19 END;
  v_code   := CASE WHEN p.line_item_code IS NULL THEN NULL ELSE p.line_item_code || '-R' || c.cancellation_id END;

  -- The same part as the parent, corrected part number and class included, for the cancelled quantity.
  INSERT INTO qvm_new_apps.quotation_items
    (quotation_id, part_description, part_number, quantity, brand_class, part_photo, item_status,
     main_brand, model, customer_id, vin, year, part_category,
     price_before_vat, total_price_before_vat, discount_percent, agency_price, estimated_price,
     line_item_code, pn_state, extraction_status, reissued_from_item_id, created_at, updated_at)
  VALUES
    (p.quotation_id, p.part_description, COALESCE(v_ci.final_part_number, p.part_number), v_qty,
     COALESCE(v_ci.final_brand_class, p.brand_class), p.part_photo, v_status,
     p.main_brand, p.model, p.customer_id, p.vin, p.year, p.part_category,
     p.price_before_vat,
     CASE WHEN p.total_price_before_vat IS NULL OR COALESCE(p.quantity, 0) <= 0 THEN p.total_price_before_vat
          ELSE round(((p.total_price_before_vat / p.quantity) * v_qty)::numeric, 2) END,
     p.discount_percent, p.agency_price, p.estimated_price,
     v_code, p.pn_state, p.extraction_status, p.quotation_item_id, now(), now())
  RETURNING quotation_item_id INTO v_child;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by) VALUES (v_child, v_status, v_uid);

  IF p_cost_id IS NOT NULL THEN
    -- Every priced offer on the parent, except the cancelling vendor's and the unavailable ones.
    INSERT INTO qvm_new_apps.quotation_vendor_items
      (quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost, discount_percent, from_database,
       vendor_item_status, sla, sla_hours, available_brand_class, available_brand_id, origin_country_id,
       vendor_part_number, agency_price, item_shipping, note, price_source, created_by, created_at, updated_at)
    SELECT v_child, s.vendor_id, s.quotation_vendor_id, false, s.cost, s.discount_percent, s.from_database,
           158, s.sla, s.sla_hours, s.available_brand_class, s.available_brand_id, s.origin_country_id,
           s.vendor_part_number, s.agency_price, s.item_shipping, s.note, s.price_source, v_uid, now(), now()
      FROM qvm_new_apps.quotation_vendor_items s
     WHERE s.quotation_item_id = c.quotation_item_id
       AND COALESCE(s.cost, 0) > 0
       AND COALESCE(s.vendor_item_status, 0) <> 161
       AND (c.vendor_id IS NULL OR s.vendor_id <> c.vendor_id);

    SELECT cp.cost_id INTO v_sel FROM qvm_new_apps.quotation_vendor_items cp
     WHERE cp.quotation_item_id = v_child AND cp.quotation_vendor_id = v_src.quotation_vendor_id;
    SELECT cp.cost_id INTO v_cp FROM qvm_new_apps.quotation_vendor_items cp
     WHERE cp.quotation_item_id = v_child
       AND cp.quotation_vendor_id = (SELECT o.quotation_vendor_id FROM qvm_new_apps.quotation_vendor_items o WHERE o.cost_id = p.customer_price_cost_id);

    UPDATE qvm_new_apps.quotation_items
       SET selected_cost_id = v_sel, customer_price_cost_id = COALESCE(v_cp, v_sel), updated_at = now()
     WHERE quotation_item_id = v_child;

    SELECT co.confirmed_order_id INTO v_order FROM qvm_new_apps.confirmed_orders co
     WHERE co.quotation_id = p.quotation_id ORDER BY co.confirmed_order_id LIMIT 1;
    IF v_order IS NULL THEN
      INSERT INTO qvm_new_apps.confirmed_orders (quotation_id, created_at, updated_at)
      VALUES (p.quotation_id, now(), now()) RETURNING confirmed_order_id INTO v_order;
    END IF;
    INSERT INTO qvm_new_apps.confirmed_items
      (confirmed_order_id, quotation_item_id, approved_qty, item_status, final_part_number, final_brand_class, created_at, updated_at)
    VALUES (v_order, v_child, v_qty, 19, COALESCE(v_ci.final_part_number, p.part_number), COALESCE(v_ci.final_brand_class, p.brand_class), now(), now())
    RETURNING confirmed_item_id INTO v_new_ci;
    INSERT INTO qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by) VALUES (v_new_ci, 19, v_uid);

    SELECT vendor_name INTO v_vendor_name FROM qvm_new_apps.vendors WHERE vendor_id = v_src.vendor_id;
  END IF;

  UPDATE qvm_new_apps.quotation_item_cancellations
     SET reissued_item_id = v_child, reissued_at = now(), reissued_by = v_uid
   WHERE cancellation_id = p_cancellation_id;

  INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
  VALUES ('quotation_items', p.quotation_item_id, v_uid, true,
          format('%s of the cancelled quantity put back on the order as a new line%s', v_qty,
                 CASE WHEN p_cost_id IS NULL THEN ', to be sent to vendors' ELSE ', confirmed on ' || COALESCE(v_vendor_name, 'another vendor') END));

  RETURN jsonb_build_object('status', true, 'data', jsonb_build_object(
    'quotation_item_id', v_child, 'item_status', v_status, 'quantity', v_qty,
    'selected_cost_id', v_sel, 'confirmed_item_id', v_new_ci));
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.reissue_cancelled_quantity(bigint, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.reissue_cancelled_quantity(bigint, bigint, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.reissue_cancelled_quantity(p_cancellation_id bigint, p_cost_id bigint DEFAULT NULL, p_quantity integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT qvm_new_apps.reissue_cancelled_quantity(p_cancellation_id, p_cost_id, p_quantity);
$function$;
GRANT EXECUTE ON FUNCTION public.reissue_cancelled_quantity(bigint, bigint, integer) TO authenticated;


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

    INSERT INTO qvm_new_apps.item_request_decisions
      (confirmed_item_id, request_kind, decision, requested_qty, full_request, reason_id, decided_by)
    VALUES (p_confirmed_item_id, 'cancellation', 'approved', v_requested_qty, v_full, v_row.cancellation_reason, v_uid);

    -- The cancelled quantity is still wanted until the desk says otherwise: recorded so the pricing
    -- page can buy it again, from another vendor who priced the line or through a fresh RFQ. Whose
    -- cancellation it was is read from who raised the request.
    INSERT INTO qvm_new_apps.quotation_item_cancellations
      (quotation_item_id, confirmed_item_id, purchase_item_id, vendor_id, qty, source, reason_id, created_by)
    SELECT v_row.quotation_item_id, p_confirmed_item_id, v_pi_id,
           (SELECT qvi.vendor_id FROM qvm_new_apps.purchase_items pi2
              JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi2.cost_id
             WHERE pi2.purchase_item_id = v_pi_id),
           v_requested_qty,
           COALESCE((SELECT CASE ud.user_type WHEN 183 THEN 'workshop' WHEN 205 THEN 'vendor' WHEN 185 THEN 'qparts' END
                       FROM qvm_new_apps.status_logs sl
                       JOIN qvm_new_apps.user_data ud ON ud.user_id = sl.status_changed_by
                      WHERE sl.confirmed_item_id = p_confirmed_item_id AND sl.item_status = 24
                      ORDER BY sl.created_at DESC LIMIT 1), 'workshop'),
           v_row.cancellation_reason, v_uid;
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

    INSERT INTO qvm_new_apps.item_request_decisions
      (confirmed_item_id, request_kind, decision, requested_qty, full_request, return_type, reason_id, decided_by)
    VALUES (p_confirmed_item_id, 'return', 'approved', v_requested_qty, v_full, p_return_type, v_row.client_return_reason, v_uid);
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

CREATE OR REPLACE FUNCTION qvm_new_apps.lines_cleared_for_purchase(p_quotation_id bigint)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- Empty when the policy requires nobody: then nothing is cleared BY APPROVAL — a priced line is
  -- bought as it is, through confirm_priced_lines. A line re-issued for a cancelled quantity stands
  -- on its parent's approvals: same part, same customer price, already signed for.
  SELECT COALESCE(ARRAY(
    SELECT qi.quotation_item_id
      FROM qvm_new_apps.quotation_items qi
      CROSS JOIN qvm_new_apps.quotation_approval_policy(p_quotation_id) pol
     WHERE qi.quotation_id = p_quotation_id
       AND (pol.requires_workshop OR pol.requires_customer)
       AND (NOT pol.requires_workshop OR COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'workshop')))
       AND (NOT pol.requires_customer OR COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'client')))
     ORDER BY qi.quotation_item_id), ARRAY[]::bigint[]);
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- The signatures the customer's policy asks for, before any purchase. A customer may require the
  -- workshop's confirmation of سعر الجملة, the customer's approval of سعر العميل, both (the default)
  -- or neither — with neither, a priced line may be bought as it is. An order with no end customer
  -- is judged the old way: both signatures, and only once it has been through the approval flow.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_items) e
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
      CROSS JOIN LATERAL qvm_new_apps.quotation_approval_policy(qi.quotation_id) pol
     WHERE CASE
             WHEN pol.has_end_customer THEN
               (pol.requires_workshop OR pol.requires_customer)
               AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.lines_cleared_for_purchase(qi.quotation_id)))
             ELSE
               EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_rounds r WHERE r.quotation_id = qi.quotation_id)
               AND NOT (COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'workshop'))
                        AND COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'client')))
           END
  ) THEN
    RETURN jsonb_build_object('status', false,
      'message', 'Every line on a purchase order must first be approved by everyone this customer requires');
  END IF;


  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      -- When the buyer took one of the vendor's alternatives instead of the part asked for, the PO is
      -- for the alternative, at the alternative's price. Written here as final_purchase_price so every
      -- reader that already prefers it over the line's cost gets the right number. Left NULL for an
      -- ordinary line, which is exactly what happened before.
      final_purchase_price,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      (SELECT ch.unit_price
         FROM qvm_new_apps.quotation_vendor_items qvi
         JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
        WHERE qvi.cost_id = NULLIF(e->>'cost_id','')::INT),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id, cost_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
    RETURNING ci.confirmed_item_id, ci.quotation_item_id
  ),
  -- Save cost_id back to quotation_items so it can be restored when reopening pricing modal
  cost_id_update AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET cost_id = ii.cost_id, updated_at = NOW()
    FROM inserted_items ii
    JOIN status_update su ON su.confirmed_item_id = ii.confirmed_item_id
    WHERE qi.quotation_item_id = su.quotation_item_id
      AND ii.cost_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id
  JOIN status_update su ON su.confirmed_item_id = pi.confirmed_item_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_vendor_pricings(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'status', true,
        'message', 'success',
        'data', jsonb_agg(
            jsonb_build_object(
                'quotation_item_id', qi.quotation_item_id,
                'quotation_id', qi.quotation_id,
                'shipping_price', q.shipping_price,
                'customer_id', qi.customer_id,
                'vin', qi.vin,
                'main_brand', lcd_mb.list_data,
                'model', qi.model,
                'part_description', qi.part_description,
                'part_number', qi.part_number,
                'quantity', qi.quantity,
                -- The class by NAME, as main_brand and part_category already are; the id rides beside it
                -- for anything that needs to write it back.
                'brand_class', lcd_bc.list_data,
                'brand_class_id', qi.brand_class,
                'part_photo', qi.part_photo,
                -- Every alternative on the line, from every source, for the desk's one list.
                'item_alternatives', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
                             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
                             'part_number', a.part_number,
                             'brand_class_name', bc.list_data, 'brand_name', br.list_data,
                             'origin', COALESCE(oc.name_ar, oc.name_en),
                             'unit_price', a.unit_price, 'available_quantity', a.available_quantity, 'delivery_days', a.delivery_days,
                             'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
                             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
                      FROM qvm_new_apps.quotation_vendor_item_alternatives a
                      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                     WHERE a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb),
                -- How many of the line are already on purchase orders (cancelled purchase lines excluded).
                'ordered_qty', (SELECT COALESCE(SUM(pi.approved_qty), 0)::int
                                  FROM qvm_new_apps.purchase_items pi
                                  JOIN qvm_new_apps.quotation_vendor_items pq ON pq.cost_id = pi.cost_id
                                  LEFT JOIN qvm_new_apps.list_data pst ON pst.list_data_id = pi.vendor_item_status
                                 WHERE pq.quotation_item_id = qi.quotation_item_id
                                   AND COALESCE(pst.list_data, '') NOT ILIKE 'cancel%'),
                -- Every note on the line, internal ones included: this is the buying desk's page.
                -- A quantity cancelled after confirmation — by the vendor on the purchase order or by an
                -- approved request — and what the desk did about it. A line re-issued for such a quantity
                -- names the line it came from.
                'reissued_from_item_id', qi.reissued_from_item_id,
                'reissued_from_part_number', (SELECT p.part_number FROM qvm_new_apps.quotation_items p
                                               WHERE p.quotation_item_id = qi.reissued_from_item_id),
                'cancellations', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                             'cancellation_id', c.cancellation_id, 'qty', c.qty, 'source', c.source,
                             'vendor_id', c.vendor_id, 'vendor_name', cv.vendor_name,
                             'reason', crs.list_data, 'note', c.note, 'created_at', c.created_at,
                             'reissued_item_id', c.reissued_item_id, 'reissued_at', c.reissued_at,
                             'reissued_status', ri.item_status) ORDER BY c.cancellation_id DESC)
                      FROM qvm_new_apps.quotation_item_cancellations c
                      LEFT JOIN qvm_new_apps.vendors cv ON cv.vendor_id = c.vendor_id
                      LEFT JOIN qvm_new_apps.list_data crs ON crs.list_data_id = c.reason_id
                      LEFT JOIN qvm_new_apps.quotation_items ri ON ri.quotation_item_id = c.reissued_item_id
                     WHERE c.quotation_item_id = qi.quotation_item_id), '[]'::jsonb),
                'item_notes_count', (SELECT COUNT(*)::int FROM qvm_new_apps.notes n
                                      WHERE n.note_type = 'quotation_items' AND n.type_id = qi.quotation_item_id),
                'item_status', qi.item_status,
                'alternative_part_number', qi.alternative_part_number,
                'price_before_vat', qi.price_before_vat,
                'discount_percent', qi.discount_percent,
                'total_price_before_vat', qi.total_price_before_vat,
                'cost_id', qi.cost_id,
                'purchase_cost', qvi_pur.cost,
                'purchase_vendor', v_pur.vendor_name,
                'part_category', lcd_pc.list_data,
                'agency_price', qi.agency_price,
                'created_at', qi.created_at,
                'updated_at', qi.updated_at,
                'vendor_pricing', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'cost_id', qvi.cost_id,
                            'quotation_item_id', qvi.quotation_item_id,
                            'cost', qvi.cost,
                            'vendor_name', v.vendor_name,
                            'vendor_branch_id', qv.vendor_branch_id,
                            'vendor_branch_city', vb.city,
                            'vendor_branch_name', vb.branch_name,
                            'vendor_shipping_cost', (
                                SELECT pi.vendor_shipping_cost
                                FROM qvm_new_apps.purchase_items pi
                                WHERE pi.cost_id = qvi.cost_id
                                LIMIT 1
                            ),
                            'item_shipping', qvi.item_shipping,
                            'vendor_item_status', lcd_vis.list_data,
                            'vendor_item_status_id', qvi.vendor_item_status,
                            'discount_percent', qvi.discount_percent,
                            'agency_price', qvi.agency_price,
                            'from_database', qvi.from_database,
                            'sla', qvi.sla,
                            'best_cost', qvi.best_cost,
                            'available_quantity', qvi.available_quantity,
                            'confirmed_quantity', qvi.confirmed_quantity,
                            'quotation_vendor_id', qvi.quotation_vendor_id,
                            'available_brand_class', lcd_abc.list_data,
                            'alternative_part_number', qvi.alternative_part_number,
                            -- The alternatives this vendor offered on this line, and which one the
                            -- buyer chose to take instead of the part that was asked for. The
                            -- effective figures are what the purchase order and the approvals use.
                            'chosen_alternative_id', qvi.chosen_alternative_id,
                            'note', qvi.note,
                            'vendor_part_number', qvi.vendor_part_number,
                            'files', COALESCE(qvi.files, '[]'::jsonb),
                            'improvement_requested_at', qvi.improvement_requested_at,
                            'improvement_note', qvi.improvement_note,
                            'previous_cost', qvi.previous_cost,
                            'effective_cost', COALESCE(ch.unit_price, qvi.cost),
                            'effective_part_number', COALESCE(ch.part_number, qvi.vendor_part_number),
                            'alternatives', COALESCE((
                                SELECT jsonb_agg(jsonb_build_object(
                                         'alternative_id',     a.alternative_id,
                                         'source',             a.source,
                                         'part_number',        a.part_number,
                                         'brand_class_name',   bc.list_data,
                                         'brand_name',         br.list_data,
                                         'origin',             COALESCE(oc.name_ar, oc.name_en),
                                         'unit_price',         a.unit_price,
                                         'available_quantity', a.available_quantity,
                                         'delivery_days',      a.delivery_days,
                                         'note',               a.note,
                                         'photos',             a.photos,
                                         'visible_to_workshop', a.visible_to_workshop) ORDER BY a.alternative_id)
                                  FROM qvm_new_apps.quotation_vendor_item_alternatives a
                                  LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                                  LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                                  LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                                 WHERE a.cost_id = qvi.cost_id), '[]'::jsonb),
                            'created_at', qvi.created_at,
                            'updated_at', qvi.updated_at,
                            'is_best_price', (
                                qvi.cost = (
                                    SELECT MIN(cost)
                                    FROM qvm_new_apps.quotation_vendor_items
                                    WHERE quotation_item_id = qi.quotation_item_id
                                )
                            ),
                            'selling_price',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (1 + (pm.percentage)), 2)
                                    ELSE 0
                                END,
                            'profit_value',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (pm.percentage), 2)
                                    ELSE 0
                                END,
                            'profit_percentage',
                                COALESCE(pm.percentage, 0)
                        )
                    )
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    LEFT JOIN qvm_new_apps.list_data lcd_abc
                        ON qvi.available_brand_class = lcd_abc.list_data_id
                    LEFT JOIN qvm_new_apps.list_data lcd_vis
                        ON qvi.vendor_item_status = lcd_vis.list_data_id
                    LEFT JOIN qvm_new_apps.vendors v
                        ON qvi.vendor_id = v.vendor_id
                    LEFT JOIN qvm_new_apps.quotation_vendors qv
                        ON qv.quotation_vendor_id = qvi.quotation_vendor_id
                    LEFT JOIN qvm_new_apps.vendor_branches vb
                        ON vb.vendor_branch_id = qv.vendor_branch_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch
                        ON ch.alternative_id = qvi.chosen_alternative_id
                    LEFT JOIN qvm_new_apps.profit_categories pc
                        ON pc.brand_class = qi.brand_class
                       AND pc.part_category = qi.part_category
                    LEFT JOIN qvm_new_apps.cost_categories cc
                        ON qvi.cost >= (cc.cost_range->>0)::numeric
                        AND qvi.cost <  (cc.cost_range->>1)::numeric
                    LEFT JOIN qvm_new_apps.profit_margins pm
                        ON pm.profit_categories_id = pc.category_id
                        AND pm.cost_range_id = cc.cost_range_id
                  WHERE qvi.quotation_item_id = qi.quotation_item_id
                    AND (
                        cc.cost_range IS NULL
                        OR qvi.cost IS NULL
                        OR (
                            qvi.cost >= (cc.cost_range->>0)::numeric
                            AND qvi.cost <  (cc.cost_range->>1)::numeric
                        )
                    )
                )
            )
            ORDER BY qi.quotation_item_id DESC
        )
    )
    INTO result
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotations q ON qi.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data lcd_pc
           ON qi.part_category = lcd_pc.list_data_id
    LEFT JOIN qvm_new_apps.list_data lcd_mb
           ON qi.main_brand = lcd_mb.list_data_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_pur
           ON qvi_pur.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.vendors v_pur
           ON v_pur.vendor_id = qvi_pur.vendor_id
    LEFT JOIN qvm_new_apps.list_data lcd_bc ON lcd_bc.list_data_id = qi.brand_class
    WHERE q.order_number = p_order_number;

    RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_supplier_confirmed_orders_paged(p_vendor_id integer, p_order_number text DEFAULT NULL::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_result JSON;
    v_offset integer := (p_page - 1) * p_page_size;
    v_total integer;
BEGIN
    SELECT COUNT(DISTINCT po.purchase_order_id)
    INTO v_total
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
    WHERE po.vendor_id = p_vendor_id
      AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
      AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids));

    SELECT json_build_object(
        'status', 'success',
        'total', v_total,
        'page', p_page,
        'page_size', p_page_size,
        'data', COALESCE((
            SELECT json_agg(po_row)
            FROM (
                SELECT json_build_object(
                    'purchase_order_id', po.purchase_order_id,
                    'po_number', 'PO-' || po.purchase_order_id,
                    'confirmed_order_id', po.confirmed_order_id,
                    'quotation_id', co.quotation_id,
                    'vendor_status', po.vendor_status,
                    'vendor_status_name', vendor_status_ld.list_data,
                    'vendor_invoice_url', po.vendor_invoice_url,
                    'vendor_invoice_number', po.vendor_invoice_number,
                    'created_at', po.created_at,
                    'vendor', json_build_object(
                        'vendor_id', v.vendor_id,
                        'vendor_name', v.vendor_name
                    ),
                    'quotation', json_build_object(
                        'order_number', q.order_number,
                        'plate_number', q.plate_number,
                        'delivery_type_name', dt_ld.list_data,
                        'account_manager', q.account_manager
                    ),
                    'total_price', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                        ), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                          ON pi_sub.cost_id = qvi_sub.cost_id
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_shipping', (
                        SELECT COALESCE(SUM(pi_sub.vendor_shipping_cost), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_with_shipping', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                            + pi_sub.vendor_shipping_cost
                        ), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                          ON pi_sub.cost_id = qvi_sub.cost_id
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_qty', (
                        SELECT COALESCE(SUM(pi_sub.approved_qty), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'items', (
                        SELECT json_agg(json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'part_description', qi_item.part_description,
                            'approved_qty', pi.approved_qty,
                            'unit_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost),
                            'total_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost, 0) * pi.approved_qty,
                            'vendor_shipping_cost', pi.vendor_shipping_cost,
                            'item_status_name', item_status_ld.list_data,
                            'vendor_item_status', pi.vendor_item_status,
                            'item_status_id', ci.item_status,
                            'received_qty', COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                                                       WHERE ri.purchase_item_id = pi.purchase_item_id), 0),
                            'returned_qty', COALESCE(pi.returned_qty, 0),
                            'outstanding_qty', GREATEST(COALESCE(pi.approved_qty, 0)
                                                        - COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                                                                     WHERE ri.purchase_item_id = pi.purchase_item_id), 0)
                                                        - COALESCE(pi.returned_qty, 0), 0),
                            'receipt_status', pi.receipt_status,
                            'request_pending', ci.item_status IN (24, 28)
                        ))
                        FROM qvm_new_apps.purchase_items pi
                        JOIN qvm_new_apps.confirmed_items ci ON pi.confirmed_item_id = ci.confirmed_item_id
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON pi.cost_id = qvi.cost_id
                        LEFT JOIN qvm_new_apps.list_data item_status_ld ON ci.item_status = item_status_ld.list_data_id
                        LEFT JOIN qvm_new_apps.quotation_items qi_item ON ci.quotation_item_id = qi_item.quotation_item_id
                        WHERE pi.purchase_order_id = po.purchase_order_id
                    )
                ) AS po_row
                FROM qvm_new_apps.purchase_orders po
                JOIN qvm_new_apps.vendors v ON po.vendor_id = v.vendor_id
                JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
                LEFT JOIN qvm_new_apps.list_data vendor_status_ld ON po.vendor_status = vendor_status_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data dt_ld ON q.delivery_type = dt_ld.list_data_id
                WHERE po.vendor_id = p_vendor_id
                  AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
                  AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids))
                ORDER BY po.created_at DESC
                LIMIT p_page_size OFFSET v_offset
            ) sub
        ), '[]'::json)
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.quick_send_item_to_vendors(p_quotation_item_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_quotation_id integer;
  v_order_number text; v_plate text; v_date date;
  v_vin text; v_brand text; v_model text; v_year text; v_class text;
  v_part_number text; v_part_desc text; v_qty integer;
  v_created jsonb := '[]'::jsonb;
  v_count int := 0;
  r record;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated');
  end if;

  select qi.quotation_id, qi.vin, qi.model, bmain.list_data, bcls.list_data,
         qi.part_number, qi.part_description, qi.quantity, qi.year::text
    into v_quotation_id, v_vin, v_model, v_brand, v_class,
         v_part_number, v_part_desc, v_qty, v_year
  from qvm_new_apps.quotation_items qi
  left join qvm_new_apps.list_data bmain on bmain.list_data_id = qi.main_brand
  left join qvm_new_apps.list_data bcls on bcls.list_data_id = qi.brand_class
  where qi.quotation_item_id = p_quotation_item_id;

  if v_quotation_id is null then
    return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id');
  end if;

  select q.order_number, q.plate_number, q.created_at::date
    into v_order_number, v_plate, v_date
  from qvm_new_apps.quotations q where q.quotation_id = v_quotation_id;

  for r in
    select qv.quotation_vendor_id, qv.vendor_id, qv.vendor_branch_id, qv.access_token
    from qvm_new_apps.quotation_vendors qv
    where qv.quotation_id = v_quotation_id
      -- A line re-issued for a cancelled quantity is not offered back to the vendor who cancelled it.
      and not exists (select 1 from qvm_new_apps.quotation_item_cancellations c
                       where c.reissued_item_id = p_quotation_item_id and c.vendor_id = qv.vendor_id)
  loop
    insert into qvm_new_apps.quotation_vendor_items (
      quotation_item_id, vendor_id, quotation_vendor_id,
      best_cost, from_database, vendor_item_status, created_by, created_at, updated_at
    ) values (
      p_quotation_item_id, r.vendor_id, r.quotation_vendor_id,
      false, false, 157, v_uid, now(), now()
    )
    on conflict on constraint quotation_vendor_items_quotation_item_qv_unique do nothing;

    -- keep each vendor's magic link alive (same 7-day window as a resend)
    update qvm_new_apps.quotation_vendors
      set token_expires_at = now() + interval '7 days'
      where quotation_vendor_id = r.quotation_vendor_id;

    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'vendor_id', r.vendor_id,
      'vendor_branch_id', r.vendor_branch_id,
      'quotation_vendor_id', r.quotation_vendor_id,
      'access_token', r.access_token
    ));
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    return jsonb_build_object('status', false, 'message', 'No vendors are attached to this quotation yet');
  end if;

  update qvm_new_apps.quotation_items
    set item_status = 237, updated_at = now()
    where quotation_item_id = p_quotation_item_id;

  insert into qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  values (p_quotation_item_id, 237, v_uid, now())
  on conflict do nothing;

  return jsonb_build_object(
    'status', true,
    'quotation_id', v_quotation_id,
    'order_number', coalesce(v_order_number, ''),
    'date', coalesce(v_date::text, now()::date::text),
    'car_data', jsonb_build_object(
      'vin', coalesce(v_vin, ''), 'make', coalesce(v_brand, ''), 'model', coalesce(v_model, ''),
      'year', coalesce(nullif(v_year, '')::int, 0), 'plate_number', coalesce(v_plate, '')
    ),
    'item_list', jsonb_build_array(jsonb_build_object(
      'part_number', coalesce(v_part_number, ''), 'part_description', coalesce(v_part_desc, ''),
      'class', coalesce(v_class, ''), 'qty', coalesce(v_qty, 1)
    )),
    'created', v_created,
    'created_count', v_count
  );
end $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 33 $$;
