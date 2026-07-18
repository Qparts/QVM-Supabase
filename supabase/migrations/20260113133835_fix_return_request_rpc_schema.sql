-- Update the process_return_request RPC function to match database version
CREATE OR REPLACE FUNCTION public.process_return_request(
  p_confirmed_item_id integer,
  p_return_type text,
  p_return_quantity integer,
  p_return_reason_id integer,
  p_user_id uuid,
  p_additional_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_confirmed_item qvm_new_apps.confirmed_items%ROWTYPE;
  v_old_status integer;
  v_new_status integer := 28; -- Return Request status
BEGIN
  -- Check authorization - just need to be logged in
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized - no user session');
  END IF;

  -- Get the confirmed item
  SELECT * INTO v_confirmed_item
  FROM qvm_new_apps.confirmed_items
  WHERE confirmed_item_id = p_confirmed_item_id;

  IF v_confirmed_item IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Confirmed item not found');
  END IF;

  -- Store old status for logging
  v_old_status := v_confirmed_item.item_status;

  -- Update the confirmed item
  UPDATE qvm_new_apps.confirmed_items SET
    item_status = v_new_status,
    client_return_reason = p_return_reason_id,
    requested_return_qty = p_return_quantity,
    updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  -- Add status log entry
  INSERT INTO qvm_new_apps.status_logs (
    confirmed_item_id,
    item_status,
    status_changed_by,
    created_at
  ) VALUES (
    p_confirmed_item_id,
    v_new_status,
    auth.uid(),
    now()
  );

  -- Add notes if provided
  IF p_additional_notes IS NOT NULL AND trim(p_additional_notes) != '' THEN
    INSERT INTO qvm_new_apps.notes (
      note_type,
      type_id,
      note_description,
      user_id,
      created_at,
      is_internal
    ) VALUES (
      'confirmed_items',
      p_confirmed_item_id,
      p_additional_notes,
      auth.uid(),
      now(),
      false
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Return request submitted successfully'
  );
END;
$function$;
