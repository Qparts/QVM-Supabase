-- Purchase-order receiving: signed goods-receipt note + partial-quantity tracking.
--
-- Quantity semantics change: purchase_receipt_round_items.received_qty now records what arrived IN
-- THAT ROUND (incremental), not a snapshot of the line's whole state. A line's received_total is the
-- SUM across its rounds, and remaining = confirmed_items.approved_qty - received_total. That makes
-- "12 ordered, 5 arrived, 7 remaining, receive 7 later" expressible, and lets a fully-received line
-- drop out of subsequent receipts.
--
-- approved_qty is read from confirmed_items, not purchase_items — the latter is only partially
-- populated (verified live: 11/21 rows).

ALTER TABLE qvm_new_apps.purchase_receipt_rounds
  ADD COLUMN IF NOT EXISTS signature text,
  ADD COLUMN IF NOT EXISTS po_number text,
  ADD COLUMN IF NOT EXISTS signed_note_at timestamptz;

COMMENT ON COLUMN qvm_new_apps.purchase_receipt_rounds.signature IS
  'Warehouse keeper signature for the goods-receipt note: a PNG data URL when drawn, plain text when typed.';
COMMENT ON COLUMN qvm_new_apps.purchase_receipt_rounds.signed_note_at IS
  'When the goods-receipt note itself was signed. signed_at/signed_by record when the round was saved.';
COMMENT ON COLUMN qvm_new_apps.purchase_receipt_round_items.received_qty IS
  'Quantity that arrived in THIS round (incremental). A line total is the SUM over its rounds.';

-- Detail for the receiving modal: adds received_total / remaining_qty / is_fully_received per line.
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
          'approved_qty', COALESCE(ci.approved_qty, 0),
          'received_total', rt.received_total,
          'remaining_qty', GREATEST(COALESCE(ci.approved_qty, 0) - rt.received_total, 0),
          'is_fully_received', (COALESCE(ci.approved_qty, 0) - rt.received_total) <= 0,
          'receipt_status', pi.receipt_status,
          'received_qty', pi.received_qty,
          'updated_at', pi.receipt_status_updated_at,
          'updated_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = pi.receipt_status_updated_by)
        ) ORDER BY pi.purchase_item_id)
        FROM qvm_new_apps.purchase_items pi
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
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

-- Saves one round. Only lines with remaining > 0 participate; each row records what arrived NOW.
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

  -- Everything already received? Nothing left to receipt.
  SELECT count(*) INTO v_open_lines
  FROM qvm_new_apps.purchase_items pi
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(ri.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.purchase_item_id = pi.purchase_item_id
  ) rt
  WHERE pi.purchase_order_id = p_purchase_order_id
    AND COALESCE(ci.approved_qty, 0) - rt.received_total > 0;

  IF v_open_lines = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'All items on this purchase order are already fully received');
  END IF;

  -- Reject any lower_qty asking for more than is actually outstanding.
  SELECT pi.purchase_item_id, (e->>'received_qty')::int AS asked, COALESCE(ci.approved_qty, 0) - rt.received_total AS remaining
  INTO v_bad
  FROM jsonb_array_elements(p_items) e
  JOIN qvm_new_apps.purchase_items pi ON pi.purchase_item_id = (e->>'purchase_item_id')::bigint
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(ri.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.purchase_item_id = pi.purchase_item_id
  ) rt
  WHERE (e->>'receipt_status') = 'lower_qty'
    AND COALESCE((e->>'received_qty')::int, 0) > COALESCE(ci.approved_qty, 0) - rt.received_total
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
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  CROSS JOIN LATERAL (
    SELECT GREATEST(COALESCE(ci.approved_qty, 0) - COALESCE((
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
      WHEN tot.received_total >= COALESCE(ci.approved_qty, 0) AND COALESCE(ci.approved_qty, 0) > 0 THEN 'received'
      ELSE ri.receipt_status
    END,
    receipt_status_updated_at = now(),
    receipt_status_updated_by = v_uid
  FROM qvm_new_apps.purchase_receipt_round_items ri
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = (
    SELECT pi2.confirmed_item_id FROM qvm_new_apps.purchase_items pi2 WHERE pi2.purchase_item_id = ri.purchase_item_id
  )
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(r2.received_qty), 0)::int AS received_total
    FROM qvm_new_apps.purchase_receipt_round_items r2 WHERE r2.purchase_item_id = ri.purchase_item_id
  ) tot
  WHERE ri.receipt_round_id = v_round_id AND ri.purchase_item_id = pi.purchase_item_id;

  RETURN jsonb_build_object('success', true, 'message', 'Receipt round saved',
    'data', jsonb_build_object('receipt_round_id', v_round_id, 'round_no', v_round_no, 'purchase_order_id', p_purchase_order_id));
END;
$function$;

-- The goods-receipt note: one round rendered as a signable document, priced at vendor cost.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_receipt_round_document(p_receipt_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_po_id bigint;
  v_result jsonb;
BEGIN
  SELECT purchase_order_id INTO v_po_id
  FROM qvm_new_apps.purchase_receipt_rounds WHERE receipt_round_id = p_receipt_round_id;

  IF v_po_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'Receipt round not found', 'data', null);
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', null);
  END IF;

  WITH lines AS (
    SELECT
      ri.purchase_item_id,
      ri.receipt_status,
      COALESCE(ri.received_qty, 0) AS received_qty,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data AS final_brand_class,
      COALESCE(qvi.cost, 0) AS unit_cost,
      COALESCE(qvi.cost, 0) * COALESCE(ri.received_qty, 0) AS line_total
    FROM qvm_new_apps.purchase_receipt_round_items ri
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_item_id = ri.purchase_item_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE ri.receipt_round_id = p_receipt_round_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'receipt_round_id', r.receipt_round_id,
      'round_no', r.round_no,
      'purchase_order_id', po.purchase_order_id,
      'po_ref', 'PO-' || po.purchase_order_id,
      'po_number', r.po_number,
      'signature', r.signature,
      'signed_note_at', r.signed_note_at,
      'signed_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = r.signed_by),
      'received_at', r.signed_at,
      'order_number', q.order_number,
      'confirmation_date', co.created_at,
      'vendor_name', vnd.vendor_name,
      'plate_number', q.plate_number,
      'vin', (SELECT qi2.vin FROM qvm_new_apps.quotation_items qi2 WHERE qi2.quotation_id = q.quotation_id AND qi2.vin IS NOT NULL LIMIT 1),
      'brand', (SELECT ld.list_data FROM qvm_new_apps.quotation_items qi3
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi3.main_brand
                WHERE qi3.quotation_id = q.quotation_id LIMIT 1),
      'model', (SELECT qi4.model FROM qvm_new_apps.quotation_items qi4 WHERE qi4.quotation_id = q.quotation_id AND qi4.model IS NOT NULL LIMIT 1),
      'items', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.purchase_item_id) FROM lines l), '[]'::jsonb),
      'total_before_vat', COALESCE((SELECT sum(line_total) FROM lines), 0),
      'vat_amount', ROUND(COALESCE((SELECT sum(line_total) FROM lines), 0) * 0.15, 2),
      'total_with_vat', ROUND(COALESCE((SELECT sum(line_total) FROM lines), 0) * 1.15, 2)
    )
  ) INTO v_result
  FROM qvm_new_apps.purchase_receipt_rounds r
  JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = r.purchase_order_id
  JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
  WHERE r.receipt_round_id = p_receipt_round_id;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.sign_purchase_receipt_round(
  p_receipt_round_id bigint,
  p_signature text,
  p_po_number text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_po_id bigint;
BEGIN
  SELECT purchase_order_id INTO v_po_id
  FROM qvm_new_apps.purchase_receipt_rounds WHERE receipt_round_id = p_receipt_round_id;

  IF v_po_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Receipt round not found');
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;
  IF p_signature IS NULL OR trim(p_signature) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Signature is required');
  END IF;

  UPDATE qvm_new_apps.purchase_receipt_rounds
  SET signature = p_signature, po_number = NULLIF(trim(COALESCE(p_po_number, '')), ''), signed_note_at = now()
  WHERE receipt_round_id = p_receipt_round_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('receipt_round_id', p_receipt_round_id));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_purchase_receipt_round_document(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.sign_purchase_receipt_round(bigint, text, text) TO authenticated;

-- public wrappers: supabase.rpc() with no schema resolves against `public`.
CREATE OR REPLACE FUNCTION public.get_purchase_receipt_round_document(p_receipt_round_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.get_purchase_receipt_round_document(p_receipt_round_id);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_purchase_receipt_round_document(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.sign_purchase_receipt_round(p_receipt_round_id bigint, p_signature text, p_po_number text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.sign_purchase_receipt_round(p_receipt_round_id, p_signature, p_po_number);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.sign_purchase_receipt_round(bigint, text, text) TO authenticated;
