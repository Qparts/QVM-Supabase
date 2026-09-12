-- Cancel/return request flow: the frontend already calls 3 RPCs that never existed
-- (cancel_rfq_items, process_cancellation_request, process_return_request), plus there was no
-- approve/reject step at all. This migration creates all of them, reusing columns that already
-- exist on confirmed_items (cancellation_reason, client_return_reason, requested_return_qty) and
-- the existing notes/add_note mechanism for the free-text field, rather than duplicating storage.
--
-- Status pipeline reminder (list_id=3): 19=Confirmed, 23=Delivered, 24=Cancellation Request,
-- 28=Return Request, 29=Return(ed), 18=Canceled.

ALTER TABLE qvm_new_apps.confirmed_items
  ADD COLUMN IF NOT EXISTS status_before_request integer;
COMMENT ON COLUMN qvm_new_apps.confirmed_items.status_before_request IS
  'item_status captured right before entering Cancellation Request(24)/Return Request(28), so a
   rejected request can revert to the correct prior stage instead of a hardcoded one.';

-- "Other" reason option, added only if genuinely missing (verified live: absent from both lists).
-- list_data_id is a GENERATED ALWAYS identity column — let it assign its own value.
INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 20, 'Other'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 20 AND list_data = 'Other');

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 23, 'Other'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 23 AND list_data = 'Other');

-- Pre-confirmation: cancel outright, no request/approval. Matches what cancel_items edge function
-- already expects (quotation_item_ids + optional reason), new_status hardcoded to 18 there.
CREATE OR REPLACE FUNCTION qvm_new_apps.cancel_rfq_items(
  p_quotation_item_ids int[],
  p_cancellation_reason int DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ids int[];
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  WITH updated AS (
    UPDATE qvm_new_apps.quotation_items
    SET item_status = 18
    WHERE quotation_item_id = ANY(p_quotation_item_ids) AND item_status < 19
    RETURNING quotation_item_id
  )
  SELECT COALESCE(array_agg(quotation_item_id), ARRAY[]::int[]) INTO v_ids FROM updated;

  INSERT INTO qvm_new_apps.status_logs(quotation_item_id, item_status, status_changed_by)
  SELECT unnest(v_ids), 18, v_uid;

  IF p_cancellation_reason IS NOT NULL AND array_length(v_ids, 1) > 0 THEN
    INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
    SELECT 'quotation_items', qi_id, v_uid, false,
           'Cancelled — reason: ' || COALESCE((SELECT list_data FROM qvm_new_apps.list_data WHERE list_data_id = p_cancellation_reason), 'n/a')
    FROM unnest(v_ids) AS qi_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('cancelled_count', COALESCE(array_length(v_ids, 1), 0)));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.cancel_rfq_items(int[], int) TO authenticated;

-- Post-confirmation cancellation request: Confirmed(19) -> Cancellation Request(24), pending approval.
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

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 24, cancellation_reason = p_cancellation_reason_id, status_before_request = 19,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, 24, v_uid);

  IF p_notes IS NOT NULL AND trim(p_notes) <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := p_notes, p_note_attachment := NULL, p_kind := 'comment') -> 'data' ->> 'note_id')::int INTO v_note_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('confirmed_item_id', p_confirmed_item_id, 'note_id', v_note_id));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.process_cancellation_request(int, int, text) TO authenticated;

-- Return request: eligible post-delivery statuses -> Return Request(28), pending approval.
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
  v_note_id int;
  v_note_text text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  SELECT item_status INTO v_current_status FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_current_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;
  IF v_current_status = ANY(ARRAY[19, 21, 22, 24, 28]) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item is not eligible for return yet');
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = 28, client_return_reason = p_return_reason_id, requested_return_qty = p_return_quantity,
      status_before_request = v_current_status, updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, 28, v_uid);

  v_note_text := COALESCE(p_additional_notes, '');
  IF trim(v_note_text) <> '' THEN
    SELECT (qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := v_note_text, p_note_attachment := NULL, p_kind := 'comment') -> 'data' ->> 'note_id')::int INTO v_note_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('confirmed_item_id', p_confirmed_item_id, 'note_id', v_note_id));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.process_return_request(int, text, int, int, text) TO authenticated;

-- Internal-only: approve a pending cancellation/return request.
CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(p_confirmed_item_id int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_status int;
  v_new_status int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT item_status INTO v_status FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_status = 24 THEN
    v_new_status := 18;
  ELSIF v_status = 28 THEN
    v_new_status := 29;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = v_new_status, status_before_request = NULL, updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, v_new_status, v_uid);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', v_new_status));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.approve_item_status_request(int) TO authenticated;

-- Internal-only: reject a pending cancellation/return request, reverting to its prior stage.
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
  SET item_status = COALESCE(v_prev, 19), status_before_request = NULL, updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, COALESCE(v_prev, 19), v_uid);

  IF p_resolution_note IS NOT NULL AND trim(p_resolution_note) <> '' THEN
    PERFORM qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := 'Request rejected: ' || p_resolution_note, p_note_attachment := NULL, p_kind := 'comment');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', COALESCE(v_prev, 19)));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.reject_item_status_request(int, text) TO authenticated;

-- Internal-only: list pending cancellation/return requests for the /#/returns-exchanges tabs.
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
      ci.requested_return_qty,
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

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_pending_item_status_requests(text) TO authenticated;
