-- Synced from QVM/test branch applied migration history (version 20260330160436, name: save_note_full_rpcs)
BEGIN;

CREATE OR REPLACE FUNCTION public.save_delivery_note_full(
  p_order_number text,
  p_client_name text,
  p_branch text,
  p_confirmation_date text,
  p_delivery_date text,
  p_final_part_number text,
  p_part_description text,
  p_main_brand text,
  p_model text,
  p_brand_class text,
  p_vin text,
  p_plate_number text,
  p_approved_quantity text,
  p_unit_price_before_vat text,
  p_total_price_before_vat text,
  p_vat text,
  p_total_price_including_vat text,
  p_confirmed_item_id integer,
  p_signature text,
  p_signature_uuid uuid,
  p_signed_by text,
  p_client_po text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_action text;
  v_confirmed_order_id integer;
  v_new_status integer := 25;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT ci.confirmed_order_id
  INTO v_confirmed_order_id
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_item_id = p_confirmed_item_id;

  IF v_confirmed_order_id IS NULL THEN
    RETURN json_build_object('status', false, 'message', 'Confirmed item not found');
  END IF;

  INSERT INTO qvm_new_apps.delivery_notes (
    order_number,
    client_name,
    branch,
    confirmation_date,
    delivery_date,
    final_part_number,
    part_description,
    main_brand,
    model,
    brand_class,
    vin,
    plate_number,
    approved_quantity,
    price_before_vat,
    total_price_before_vat,
    vat,
    total_price_including_vat,
    confirmed_item_id,
    signature,
    signed_by,
    created_at,
    updated_at
  )
  VALUES (
    p_order_number,
    p_client_name,
    p_branch,
    p_confirmation_date,
    p_delivery_date,
    p_final_part_number,
    p_part_description,
    p_main_brand,
    p_model,
    p_brand_class,
    p_vin,
    p_plate_number,
    p_approved_quantity::bigint,
    p_unit_price_before_vat::double precision,
    p_total_price_before_vat,
    p_vat,
    p_total_price_including_vat,
    p_confirmed_item_id,
    p_signature,
    p_signed_by,
    now(),
    now()
  )
  ON CONFLICT (confirmed_item_id) DO UPDATE SET
    order_number = EXCLUDED.order_number,
    client_name = EXCLUDED.client_name,
    branch = EXCLUDED.branch,
    confirmation_date = EXCLUDED.confirmation_date,
    delivery_date = EXCLUDED.delivery_date,
    final_part_number = EXCLUDED.final_part_number,
    part_description = EXCLUDED.part_description,
    main_brand = EXCLUDED.main_brand,
    model = EXCLUDED.model,
    brand_class = EXCLUDED.brand_class,
    vin = EXCLUDED.vin,
    plate_number = EXCLUDED.plate_number,
    approved_quantity = EXCLUDED.approved_quantity,
    price_before_vat = EXCLUDED.price_before_vat,
    total_price_before_vat = EXCLUDED.total_price_before_vat,
    vat = EXCLUDED.vat,
    total_price_including_vat = EXCLUDED.total_price_including_vat,
    signature = EXCLUDED.signature,
    signed_by = EXCLUDED.signed_by,
    updated_at = now();

  GET DIAGNOSTICS v_action = ROW_COUNT;

  UPDATE qvm_new_apps.deliveries d
  SET signature = p_signature,
      signature_uuid = p_signature_uuid,
      client_po = p_client_po,
      updated_at = now()
  WHERE d.confirmed_order_id = v_confirmed_order_id;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = v_new_status,
      updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

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

  RETURN json_build_object('status', true, 'message', 'Saved', 'rows', v_action);
END;
$$;


CREATE OR REPLACE FUNCTION public.save_return_note_full(
  p_order_number text,
  p_client_name text,
  p_branch text,
  p_confirmation_date text,
  p_return_date text,
  p_final_part_number text,
  p_part_description text,
  p_main_brand text,
  p_model text,
  p_brand_class text,
  p_vin text,
  p_plate_number text,
  p_return_quantity text,
  p_unit_price_before_vat text,
  p_total_price_before_vat text,
  p_vat text,
  p_total_price_including_vat text,
  p_confirmed_item_id integer,
  p_signature text,
  p_signature_uuid uuid,
  p_signed_by text,
  p_referenced_client_po text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_action text;
  v_confirmed_order_id integer;
  v_new_status integer := 215;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT ci.confirmed_order_id
  INTO v_confirmed_order_id
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_item_id = p_confirmed_item_id;

  IF v_confirmed_order_id IS NULL THEN
    RETURN json_build_object('status', false, 'message', 'Confirmed item not found');
  END IF;

  INSERT INTO qvm_new_apps.return_notes (
    order_number,
    client_name,
    branch,
    confirmation_date,
    return_date,
    final_part_number,
    part_description,
    main_brand,
    model,
    brand_class,
    vin,
    plate_number,
    return_quantity,
    price_before_vat,
    total_price_before_vat,
    vat,
    total_price_including_vat,
    confirmed_item_id,
    signature,
    signed_by,
    created_at,
    updated_at
  )
  VALUES (
    p_order_number,
    p_client_name,
    p_branch,
    p_confirmation_date,
    p_return_date,
    p_final_part_number,
    p_part_description,
    p_main_brand,
    p_model,
    p_brand_class,
    p_vin,
    p_plate_number,
    p_return_quantity::bigint,
    p_unit_price_before_vat::double precision,
    p_total_price_before_vat,
    p_vat,
    p_total_price_including_vat,
    p_confirmed_item_id,
    p_signature,
    p_signed_by,
    now(),
    now()
  )
  ON CONFLICT (confirmed_item_id) DO UPDATE SET
    order_number = EXCLUDED.order_number,
    client_name = EXCLUDED.client_name,
    branch = EXCLUDED.branch,
    confirmation_date = EXCLUDED.confirmation_date,
    return_date = EXCLUDED.return_date,
    final_part_number = EXCLUDED.final_part_number,
    part_description = EXCLUDED.part_description,
    main_brand = EXCLUDED.main_brand,
    model = EXCLUDED.model,
    brand_class = EXCLUDED.brand_class,
    vin = EXCLUDED.vin,
    plate_number = EXCLUDED.plate_number,
    return_quantity = EXCLUDED.return_quantity,
    price_before_vat = EXCLUDED.price_before_vat,
    total_price_before_vat = EXCLUDED.total_price_before_vat,
    vat = EXCLUDED.vat,
    total_price_including_vat = EXCLUDED.total_price_including_vat,
    signature = EXCLUDED.signature,
    signed_by = EXCLUDED.signed_by,
    updated_at = now();

  GET DIAGNOSTICS v_action = ROW_COUNT;

  UPDATE qvm_new_apps.returns r
  SET signature = p_signature,
      signature_uuid = p_signature_uuid,
      referenced_client_po = p_referenced_client_po,
      updated_at = now()
  WHERE r.confirmed_order_id = v_confirmed_order_id;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = v_new_status,
      updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

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

  RETURN json_build_object('status', true, 'message', 'Saved', 'rows', v_action);
END;
$$;

COMMIT;
;
