-- Synced from QVM/test branch applied migration history (version 20260624010615, name: sign_delivery_note_set_quotation_items_settled)

CREATE OR REPLACE FUNCTION public.sign_delivery_note(p_order_number text, p_signature text, p_user uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_confirmed_order_id integer;
  v_updated int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT co.confirmed_order_id
    INTO v_confirmed_order_id
  FROM qvm_new_apps.confirmed_orders co
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  WHERE q.order_number = p_order_number
  ORDER BY co.created_at DESC
  LIMIT 1;

  IF v_confirmed_order_id IS NULL THEN
    RETURN json_build_object('status', false, 'message', 'Order not found');
  END IF;

  -- Sign the delivery
  UPDATE qvm_new_apps.deliveries d
  SET signature = p_signature, signature_uuid = p_user, updated_at = now()
  WHERE d.confirmed_order_id = v_confirmed_order_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  UPDATE qvm_new_apps.delivery_notes dn
  SET signature = p_signature
  WHERE dn.order_number = p_order_number;

  -- Set confirmed_items status to 31 (Settled)
  UPDATE qvm_new_apps.confirmed_items ci
  SET item_status = 31, updated_at = NOW()
  WHERE ci.confirmed_order_id = v_confirmed_order_id;

  -- Set quotation_items status to 31 (Settled) via confirmed_items join
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 31, updated_at = NOW()
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_order_id = v_confirmed_order_id
    AND qi.quotation_item_id = ci.quotation_item_id;

  RETURN json_build_object('status', true, 'message', 'Signed', 'updated_rows', v_updated);
END;
$function$;
;
