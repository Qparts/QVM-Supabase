-- Partial return approval: split the item into two confirmed_items rows instead of marking the
-- whole line "Returned". The returned quantity becomes a new row (status 29, qty =
-- requested_return_qty); the original row's qty shrinks by that amount and reverts to whatever
-- status it was in before the return request (the remainder is still with the customer). A full
-- return (requested_return_qty >= approved_qty, or NULL) keeps the simple single-row flip.

-- Splitting a partial return into a second row requires two confirmed_items rows to share the
-- same quotation_item_id, which this constraint forbade. Checked first: no FK references this
-- unique constraint (all FKs point at confirmed_item_id, the primary key), so this is safe at the
-- referential-integrity level. One function, update_approved_qty, does an UPDATE ... WHERE
-- quotation_item_id = ... — it only ever runs at initial confirmation time, before any return
-- could exist, so it can't observe a post-split duplicate in practice; flagged as a follow-up if
-- that ever changes.
ALTER TABLE qvm_new_apps.confirmed_items DROP CONSTRAINT IF EXISTS confirmed_items_quotation_item_id_key;

ALTER TABLE qvm_new_apps.confirmed_items
  ADD COLUMN IF NOT EXISTS pending_request_note_id integer REFERENCES qvm_new_apps.notes(note_id);
COMMENT ON COLUMN qvm_new_apps.confirmed_items.pending_request_note_id IS
  'The note created by the current pending cancellation/return request, if any. On partial-return
   approval this note is re-pointed to the new split-off row so its text/attachments follow the
   returned quantity, not the remaining balance.';

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
  IF v_current_status = ANY(ARRAY[19, 24, 28]) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item is not eligible for return yet');
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

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('confirmed_item_id', p_confirmed_item_id, 'note_id', v_note_id));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(p_confirmed_item_id int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_status int;
  v_approved_qty int;
  v_requested_qty int;
  v_note_id int;
  v_new_id int;
  v_row qvm_new_apps.confirmed_items%ROWTYPE;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  v_status := v_row.item_status;

  IF v_status = 24 THEN
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 18, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, 18, v_uid);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', 18));
  END IF;

  IF v_status = 28 THEN
    v_approved_qty := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := COALESCE(v_row.requested_return_qty, v_approved_qty);

    -- Full return (requested >= all of it): simple single-row flip, same as before.
    IF v_requested_qty >= v_approved_qty THEN
      UPDATE qvm_new_apps.confirmed_items
      SET item_status = 29, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
      WHERE confirmed_item_id = p_confirmed_item_id;

      INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
      VALUES (p_confirmed_item_id, 29, v_uid);

      RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', 29, 'split', false));
    END IF;

    -- Partial return: split into a new "Returned" row for the returned qty, shrink the original.
    INSERT INTO qvm_new_apps.confirmed_items (
      confirmed_order_id, quotation_item_id, final_part_number, final_brand_class,
      approved_qty, item_status, client_return_reason, created_by, updated_by
    ) VALUES (
      v_row.confirmed_order_id, v_row.quotation_item_id, v_row.final_part_number, v_row.final_brand_class,
      v_requested_qty, 29, v_row.client_return_reason, v_uid, v_uid
    )
    RETURNING confirmed_item_id INTO v_new_id;

    IF v_row.pending_request_note_id IS NOT NULL THEN
      UPDATE qvm_new_apps.notes SET type_id = v_new_id WHERE note_id = v_row.pending_request_note_id;
    END IF;

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty = v_approved_qty - v_requested_qty,
        item_status = COALESCE(v_row.status_before_request, 23),
        client_return_reason = NULL, requested_return_qty = NULL, status_before_request = NULL,
        pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (v_new_id, 29, v_uid), (p_confirmed_item_id, COALESCE(v_row.status_before_request, 23), v_uid);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'split', true, 'returned_confirmed_item_id', v_new_id, 'returned_qty', v_requested_qty,
      'remaining_confirmed_item_id', p_confirmed_item_id, 'remaining_qty', v_approved_qty - v_requested_qty,
      'new_status', COALESCE(v_row.status_before_request, 23)
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
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, COALESCE(v_prev, 19), v_uid);

  IF p_resolution_note IS NOT NULL AND trim(p_resolution_note) <> '' THEN
    PERFORM qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id, p_is_internal := false, p_note_description := 'Request rejected: ' || p_resolution_note, p_note_attachment := NULL, p_kind := 'comment');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', COALESCE(v_prev, 19)));
END;
$function$;
