BEGIN;

CREATE OR REPLACE FUNCTION public.sign_out_for_delivery_note(
  p_order_number text,
  p_signature text,
  p_user uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_confirmed_order_id integer;
  v_delivery_id integer;
  v_updated int := 0;
  v_item record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Resolve the confirmed order
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

  -- Create deliveries record if it does not exist
  SELECT delivery_id INTO v_delivery_id
  FROM qvm_new_apps.deliveries
  WHERE confirmed_order_id = v_confirmed_order_id
  LIMIT 1;

  IF v_delivery_id IS NULL THEN
    INSERT INTO qvm_new_apps.deliveries (
      confirmed_order_id,
      delivery_date,
      shipping_price,
      shipping_cost,
      signature,
      signature_uuid
    )
    VALUES (
      v_confirmed_order_id,
      now() AT TIME ZONE 'Asia/Riyadh',
      0,
      0,
      p_signature,
      p_user
    )
    RETURNING delivery_id INTO v_delivery_id;
  ELSE
    UPDATE qvm_new_apps.deliveries
    SET signature = p_signature,
        signature_uuid = p_user,
        updated_at = now()
    WHERE delivery_id = v_delivery_id;
  END IF;

  -- Create or update delivery_notes records per confirmed item
  FOR v_item IN
    SELECT
      ci.confirmed_item_id,
      q.order_number,
      q.created_at::text AS order_date,
      COALESCE(qb.branch_name, '') AS branch,
      ld.list_data AS client_name,
      q.plate_number,
      q.model,
      COALESCE(ci.final_part_number, qi.part_number) AS final_part_number,
      qi.part_description,
      qi.main_brand,
      COALESCE(bcls.list_data, '') AS brand_class,
      COALESCE(ci.approved_qty, qi.quantity, 0) AS approved_quantity,
      COALESCE(qi.price_before_vat, 0) AS price_before_vat,
      15 AS vat,
      COALESCE(brnd.list_data, '') AS main_brand_name
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.client_branches qb ON qb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qb.list_data_id
    LEFT JOIN qvm_new_apps.list_data bcls ON bcls.list_data_id = COALESCE(ci.final_brand_class, qi.brand_class)
    LEFT JOIN qvm_new_apps.list_data brnd ON brnd.list_data_id = qi.main_brand
    WHERE ci.confirmed_order_id = v_confirmed_order_id
  LOOP
    -- Insert delivery_note if missing
    INSERT INTO qvm_new_apps.delivery_notes (
      order_number,
      client_name,
      branch,
      order_date,
      delivery_date,
      final_part_number,
      part_description,
      main_brand,
      brand_class,
      approved_quantity,
      price_before_vat,
      total_price_before_vat,
      vat,
      total_price_including_vat,
      confirmed_item_id,
      signature,
      receipt_signature_email,
      model,
      plate_number,
      status
    )
    VALUES (
      v_item.order_number,
      v_item.client_name,
      v_item.branch,
      v_item.order_date,
      now() AT TIME ZONE 'Asia/Riyadh'::text,
      v_item.final_part_number,
      v_item.part_description,
      v_item.main_brand_name,
      v_item.brand_class,
      v_item.approved_quantity,
      v_item.price_before_vat,
      ROUND((v_item.approved_quantity * v_item.price_before_vat)::numeric, 2)::text,
      v_item.vat::text,
      ROUND((v_item.approved_quantity * v_item.price_before_vat * (1 + v_item.vat / 100))::numeric, 2)::text,
      v_item.confirmed_item_id,
      p_signature,
      p_user::text,
      v_item.model,
      v_item.plate_number,
      'Delivered'
    )
    ON CONFLICT (confirmed_item_id) DO UPDATE
    SET signature = p_signature,
        receipt_signature_email = p_user::text;

    -- Create or update delivery_items row
    IF EXISTS (
      SELECT 1 FROM qvm_new_apps.delivery_items
      WHERE delivery_id = v_delivery_id AND confirmed_item_id = v_item.confirmed_item_id
    ) THEN
      UPDATE qvm_new_apps.delivery_items
      SET delivered_qty = v_item.approved_quantity,
          updated_at = now()
      WHERE delivery_id = v_delivery_id AND confirmed_item_id = v_item.confirmed_item_id;
    ELSE
      INSERT INTO qvm_new_apps.delivery_items (
        delivery_id,
        confirmed_item_id,
        delivered_qty
      )
      VALUES (
        v_delivery_id,
        v_item.confirmed_item_id,
        v_item.approved_quantity
      );
    END IF;
  END LOOP;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  -- Mark quotation items as Delivered (status id 23)
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 23
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.quotation_item_id = qi.quotation_item_id
    AND ci.confirmed_order_id = v_confirmed_order_id;

  RETURN json_build_object(
    'status', true,
    'message', 'Delivery note created and signed',
    'updated_rows', v_updated
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sign_out_for_delivery_note(text, text, uuid) TO authenticated;

COMMIT;
