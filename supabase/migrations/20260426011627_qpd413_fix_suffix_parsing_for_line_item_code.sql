-- Synced from QVM/test branch applied migration history (version 20260426011627, name: qpd413_fix_suffix_parsing_for_line_item_code)
BEGIN;

-- QPD-413: Fix integer cast by extracting numeric suffix only when pattern matches
CREATE OR REPLACE FUNCTION public.add_rfq_item_inline(
  p_quotation_id int,
  p_part_number text DEFAULT NULL,
  p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1,
  p_brand_class int DEFAULT NULL,
  p_part_photo text DEFAULT NULL,
  p_initial_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_order_number text;
  v_next_index int;
  v_line_item_code text;
  v_item_id int;
  v_brand_class_name text;
BEGIN
  IF p_brand_class IS NULL THEN
    RETURN jsonb_build_object('status','error','message','brand_class is required','quotation_item_id', NULL);
  END IF;

  SELECT order_number INTO v_order_number
  FROM qvm_new_apps.quotations
  WHERE quotation_id = p_quotation_id;

  IF v_order_number IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Invalid quotation_id','quotation_item_id', NULL);
  END IF;

  -- Safely extract numeric suffix only when pattern matches: <anything>-<digits>
  SELECT COALESCE(
    MAX(
      CASE
        WHEN qi.line_item_code ~ '-[0-9]+$' THEN substring(qi.line_item_code from '([0-9]+)$')::int
        ELSE NULL
      END
    ), 0
  ) + 1
  INTO v_next_index
  FROM qvm_new_apps.quotation_items qi
  WHERE qi.quotation_id = p_quotation_id;

  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    part_description,
    part_number,
    quantity,
    brand_class,
    part_photo,
    created_at,
    updated_at,
    line_item_code
  ) VALUES (
    p_quotation_id,
    NULLIF(p_part_description, ''),
    NULLIF(p_part_number, ''),
    COALESCE(p_quantity, 1),
    p_brand_class,
    p_part_photo,
    NOW(),
    NOW(),
    v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  IF p_initial_note IS NOT NULL AND btrim(p_initial_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items',
        p_type_id := v_item_id,
        p_note_description := p_initial_note,
        p_note_id := NULL,
        p_is_internal := false
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  SELECT list_data INTO v_brand_class_name FROM qvm_new_apps.list_data WHERE list_data_id = p_brand_class;

  RETURN jsonb_build_object(
    'status','success',
    'message','Item added',
    'quotation_item_id', v_item_id,
    'item_status_id', NULL,
    'brand_class_id', p_brand_class,
    'brand_class', v_brand_class_name
  );
END;
$function$;

COMMIT;;
