-- Cancelled and returned items reach the quotation line, and lock the vendor out of pricing.
--
-- The cancel/return flow only ever wrote confirmed_items.item_status. Every dashboard reads
-- quotation_items.item_status instead — verified: rfq_dashboard_paged, get_orders_with_item_status,
-- get_vendor_quotation_details and get_internal_dashboard all read qi.item_status — so a cancelled
-- or returned item still showed as Delivered everywhere. Live before this migration:
--
--   confirmed_item 31565  Canceled(18)        -> quotation line said Delivered(23)
--   confirmed_item 31583  Return(29)          -> quotation line said Out for Delivery(22)
--   confirmed_item 31593  partial return of 2 -> approved_qty 9 but quotation quantity still 11
--
-- Mirroring the status back onto the quotation line is how the rest of the pipeline already works:
-- confirm_cart_items and insert_confirmed_items both set quotation_items.item_status at
-- confirmation, and Processing/Out for Delivery/Delivered all show up there. Cancel and return were
-- simply the transitions nobody mirrored.
--
-- Two triggers on quotation_items fire when item_status changes, and both are wanted here: the
-- notification rules dispatch (a cancellation is exactly the kind of thing to notify about) and the
-- Google-sheet status writer. trg_push_vendor_item_on_accept fires only on
-- "Added by Vendor" -> "Sent To Vendor" and cannot be reached by these statuses.

-- 1. The mirror --------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id int)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation_item_id int;
  v_status int;
  v_qty int;
  v_vendor_status int;
BEGIN
  SELECT ci.quotation_item_id, ci.item_status, GREATEST(COALESCE(ci.approved_qty, 0), 0)
    INTO v_quotation_item_id, v_status, v_qty
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_item_id = p_confirmed_item_id;

  IF v_quotation_item_id IS NULL THEN
    RETURN;
  END IF;

  -- The quotation line follows the confirmed line: status always, quantity whenever a return has
  -- reduced it. Guarded so a no-op change does not fire the status triggers for nothing.
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = v_status,
      quantity    = CASE WHEN v_qty > 0 THEN v_qty ELSE qi.quantity END,
      updated_at  = now()
  WHERE qi.quotation_item_id = v_quotation_item_id
    AND (qi.item_status IS DISTINCT FROM v_status
         OR (v_qty > 0 AND qi.quantity IS DISTINCT FROM v_qty));

  -- Canceled(18) and Returned(29) are terminal: the vendor has nothing left to price, so every
  -- vendor line for this item moves to the matching vendor_status (list 15) and the pricing RPC
  -- refuses to touch them. A pending request (24/28) deliberately does NOT lock anyone — it may
  -- still be rejected.
  v_vendor_status := CASE v_status WHEN 18 THEN 160   -- الغاء
                                   WHEN 29 THEN 167   -- تم الارجاع
                                   ELSE NULL END;

  IF v_vendor_status IS NOT NULL THEN
    UPDATE qvm_new_apps.quotation_vendor_items qvi
    SET vendor_item_status = v_vendor_status,
        updated_at = now()
    WHERE qvi.quotation_item_id = v_quotation_item_id
      AND COALESCE(qvi.vendor_item_status, 0) <> v_vendor_status;

  ELSIF v_qty > 0 THEN
    -- Partial return: nobody can still be offering more than is now wanted. LEAST so a vendor who
    -- offered less than the new quantity keeps their own number.
    UPDATE qvm_new_apps.quotation_vendor_items qvi
    SET available_quantity = v_qty,
        updated_at = now()
    WHERE qvi.quotation_item_id = v_quotation_item_id
      AND qvi.available_quantity IS NOT NULL
      AND qvi.available_quantity > v_qty;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.sync_confirmed_item_to_quotation(int) TO authenticated;

-- 2. Call it from every transition ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.process_cancellation_request(
  p_confirmed_item_id int,
  p_cancellation_reason_id int,
  p_notes text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_current_status int;
  v_note_id int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT item_status INTO v_current_status FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_current_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;
  IF v_current_status <> 19 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item is not in Confirmed status');
  END IF;

  IF p_notes IS NOT NULL AND trim(p_notes) <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := p_notes, p_note_attachment := NULL, p_kind := 'comment') -> 'data' ->> 'note_id')::int INTO v_note_id;
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 24, cancellation_reason = p_cancellation_reason_id, status_before_request = 19,
      pending_request_note_id = v_note_id, updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, 24, v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('confirmed_item_id', p_confirmed_item_id, 'note_id', v_note_id));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.process_return_request(
  p_confirmed_item_id int,
  p_return_type text,
  p_return_quantity int,
  p_return_reason_id int,
  p_additional_notes text DEFAULT NULL
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
  -- Nothing downstream could act on a request for more than the client actually holds.
  IF p_return_quantity IS NOT NULL AND p_return_quantity > v_approved_qty THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('Return quantity %s exceeds the %s on this item', p_return_quantity, v_approved_qty));
  END IF;

  v_note_text := COALESCE(p_additional_notes, '');
  IF trim(v_note_text) <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := v_note_text, p_note_attachment := NULL, p_kind := 'comment') -> 'data' ->> 'note_id')::int INTO v_note_id;
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 28, client_return_reason = p_return_reason_id, requested_return_qty = p_return_quantity,
      status_before_request = v_current_status, pending_request_note_id = v_note_id, updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, 28, v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('confirmed_item_id', p_confirmed_item_id, 'note_id', v_note_id));
END;
$function$;

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

  IF v_row.item_status = 24 THEN
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 18, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, 18, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

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
    v_remaining  := CASE WHEN v_full THEN v_approved_qty ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 29 ELSE COALESCE(v_row.status_before_request, 23) END;

    -- Exchange (133) and Return to Supplier (135) both physically send the goods back, so both come
    -- off the purchase order. Return to Stock (134) does not: QVM keeps the part and still owes for it.
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

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

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

  SELECT item_status, status_before_request INTO v_status, v_prev FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_status IS NULL OR v_status NOT IN (24, 28) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = COALESCE(v_prev, 19), status_before_request = NULL, pending_request_note_id = NULL,
      requested_return_qty = NULL,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, COALESCE(v_prev, 19), v_uid);

  -- Puts the quotation line back where it was, so a rejected request leaves no trace on the
  -- dashboards or on the vendor's view.
  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  IF p_resolution_note IS NOT NULL AND trim(p_resolution_note) <> '' THEN
    PERFORM qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := 'Request rejected: ' || p_resolution_note, p_note_attachment := NULL, p_kind := 'comment');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', COALESCE(v_prev, 19)));
END;
$function$;

-- 3. Refuse vendor pricing on a cancelled or returned line ---------------------------------------
-- The bulk update had no gate of any kind: it wrote whatever cost_id it was handed. Blocked lines
-- come back in their own array rather than failing the whole batch, so a vendor saving a grid of
-- prices still gets the rest of their work saved.

CREATE OR REPLACE FUNCTION qvm_new_apps.update_quotation_vendor_items_bulk(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  updated jsonb;
  not_found jsonb;
  blocked jsonb;
BEGIN
  WITH changes AS (
    SELECT
      (x->>'cost_id')::int                                      AS cost_id,
      x->>'alternative_part_number'                             AS alternative_part_number,
      NULLIF(x->>'available_brand_class','')::int               AS available_brand_class,
      NULLIF(x->>'available_quantity','')::int                  AS available_quantity,
      NULLIF(x->>'cost','')::numeric                            AS cost,
      NULLIF(x->>'sla','')                                      AS sla,
      NULLIF(x->>'discount_percent','')::numeric               AS discount_percent,
      NULLIF(x->>'agency_price','')::numeric                   AS agency_price,
      NULLIF(x->>'vendor_item_status','') ::int                AS vendor_item_status,
      NULLIF(x->>'price_source','')                            AS price_source,
      CASE WHEN x ? 'vendor_part_number' THEN x->>'vendor_part_number' ELSE NULL END AS vendor_part_number,
      (x ? 'vendor_part_number')                               AS has_vpn
    FROM jsonb_array_elements(p_items) AS x
  ),
  -- Cancelled(18) / Returned(29) on the quotation line, or a vendor line already stood down.
  locked AS (
    SELECT c.cost_id,
           COALESCE(ld.list_data, 'Cancelled or returned') AS reason
    FROM changes c
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = c.cost_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
    WHERE qi.item_status IN (18, 29)
       OR COALESCE(qvi.vendor_item_status, 0) IN (160, 167)
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_vendor_items qvi
    SET
      alternative_part_number = COALESCE(c.alternative_part_number, qvi.alternative_part_number),
      available_brand_class   = COALESCE(c.available_brand_class, qvi.available_brand_class),
      available_quantity      = COALESCE(c.available_quantity, qvi.available_quantity),
      cost                    = COALESCE(c.cost, qvi.cost),
      sla                     = COALESCE(c.sla, qvi.sla),
      discount_percent        = COALESCE(c.discount_percent, qvi.discount_percent),
      agency_price            = COALESCE(c.agency_price, qvi.agency_price),
      vendor_item_status      = COALESCE(c.vendor_item_status, qvi.vendor_item_status),
      price_source            = COALESCE(c.price_source, qvi.price_source),
      -- vendor_part_number is set whenever the key is present (allows clearing to empty/NULL).
      vendor_part_number      = CASE WHEN c.has_vpn THEN c.vendor_part_number ELSE qvi.vendor_part_number END,
      best_cost               = FALSE,
      updated_at              = NOW()
    FROM changes c
    WHERE qvi.cost_id = c.cost_id
      AND NOT EXISTS (SELECT 1 FROM locked l WHERE l.cost_id = c.cost_id)
    RETURNING qvi.cost_id, qvi.alternative_part_number, qvi.available_brand_class, qvi.available_quantity,
              qvi.cost, qvi.sla, qvi.discount_percent, qvi.agency_price, qvi.vendor_item_status,
              qvi.price_source, qvi.vendor_part_number, qvi.best_cost
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(upd.*)), '[]'::jsonb) INTO updated FROM upd;

  SELECT COALESCE(jsonb_agg(to_jsonb(c.*)), '[]'::jsonb) INTO not_found
  FROM (
    SELECT (x->>'cost_id')::int AS cost_id
    FROM jsonb_array_elements(p_items) AS x
    WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_items q WHERE q.cost_id = (x->>'cost_id')::int)
  ) AS c;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('cost_id', b.cost_id, 'reason', b.reason)), '[]'::jsonb)
  INTO blocked
  FROM (
    SELECT qvi.cost_id, COALESCE(ld.list_data, 'Cancelled or returned') AS reason
    FROM jsonb_array_elements(p_items) AS x
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = (x->>'cost_id')::int
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
    WHERE qi.item_status IN (18, 29)
       OR COALESCE(qvi.vendor_item_status, 0) IN (160, 167)
  ) b;

  RETURN jsonb_build_object('status', true, 'message', 'Bulk update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0), 'updated', updated,
    'not_found', not_found, 'blocked', blocked);
END;
$function$;

-- 4. Bring the existing rows into line -----------------------------------------------------------
-- Scoped to items this feature owns — cancelled, returned, or with a pending request — and NOT to
-- every row where the two statuses differ. Those two columns drift for unrelated reasons: 18 rows
-- differ live, and 7 of them have the quotation line legitimately AHEAD of the confirmed line
-- (Processing vs Out for Delivery / Delivered). Syncing those would drag them backwards.
--
-- The notification trigger is disabled for the backfill only: these items were cancelled or
-- returned days ago, and dispatching "your item was cancelled" now would be a burst of false
-- alarms. Going forward the trigger fires normally, which is what we want.

DO $backfill$
DECLARE
  r record;
  n int := 0;
BEGIN
  ALTER TABLE qvm_new_apps.quotation_items DISABLE TRIGGER trg_dispatch_notification_rules_qi;

  FOR r IN
    SELECT ci.confirmed_item_id
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE (ci.item_status IN (18, 24, 28, 29) OR COALESCE(ci.returned_qty, 0) > 0)
      AND (qi.item_status IS DISTINCT FROM ci.item_status
           OR (COALESCE(ci.approved_qty, 0) > 0 AND qi.quantity IS DISTINCT FROM ci.approved_qty))
    ORDER BY ci.confirmed_item_id
  LOOP
    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(r.confirmed_item_id);
    n := n + 1;
  END LOOP;

  ALTER TABLE qvm_new_apps.quotation_items ENABLE TRIGGER trg_dispatch_notification_rules_qi;

  RAISE NOTICE 'synced % confirmed items onto their quotation lines', n;
END
$backfill$;
