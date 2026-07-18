CREATE OR REPLACE FUNCTION public.add_rfq_item(
  p_quotation_id integer,
  p_part_number text,
  p_part_description text,
  p_quantity integer,
  p_brand_class integer,
  p_part_photo text DEFAULT NULL,
  p_note_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, qvm_new_apps
AS $$
DECLARE
  v_customer_id integer;
  v_vin text;
  v_main_brand integer;
  v_model text;
  v_year text;
  v_new_item_id integer;
  v_item_status integer;
BEGIN
  v_item_status := CASE
    WHEN p_part_number IS NOT NULL AND btrim(p_part_number) <> '' THEN 235
    ELSE 236
  END;
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_quotation_id IS NULL OR p_quotation_id <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (quotation_id)');
  END IF;

  -- Require at least part number OR part description (not both individually)
  IF (p_part_number IS NULL OR btrim(p_part_number) = '') AND (p_part_description IS NULL OR btrim(p_part_description) = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing input - please provide part number or part description');
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (quantity)');
  END IF;

  IF p_brand_class IS NULL OR p_brand_class <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (brand_class)');
  END IF;

  -- Validate that brand_class exists in list_data table
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.list_data 
    WHERE list_data_id = p_brand_class
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid brand class - does not exist in system');
  END IF;

  SELECT qi.customer_id, qi.vin, qi.main_brand, qi.model, qi.year
  INTO v_customer_id, v_vin, v_main_brand, v_model, v_year
  FROM qvm_new_apps.quotation_items qi
  WHERE qi.quotation_id = p_quotation_id
  ORDER BY qi.quotation_item_id ASC
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'RFQ has no existing items to derive branch info');
  END IF;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    part_number,
    part_description,
    quantity,
    brand_class,
    part_photo,
    item_status,
    customer_id,
    vin,
    main_brand,
    model,
    year,
    created_at,
    updated_at
  )
  VALUES (
    p_quotation_id,
    p_part_number,
    p_part_description,
    p_quantity,
    p_brand_class,
    p_part_photo,
    v_item_status,
    v_customer_id,
    v_vin,
    v_main_brand,
    v_model,
    v_year,
    now(),
    now()
  )
  RETURNING quotation_item_id INTO v_new_item_id;

  -- Insert note if provided
  IF p_note_description IS NOT NULL AND btrim(p_note_description) != '' THEN
    INSERT INTO qvm_new_apps.notes (
      note_type,
      type_id,
      note_description,
      user_id,
      is_internal,
      created_at,
      updated_at
    )
    VALUES (
      'quotation_items',
      v_new_item_id,
      p_note_description,
      auth.uid(),
      FALSE,
      now(),
      now()
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'quotation_item_id', v_new_item_id,
    'item_status_id', v_item_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_rfq_item(integer, text, text, integer, integer, text, text) TO authenticated;
