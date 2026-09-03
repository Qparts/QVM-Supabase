-- Return is now available from Processing(21) onward, not just Delivered(23)+, matching the
-- frontend's corrected gating in orderItemsColumns.tsx / OrderItemCard.tsx.
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
