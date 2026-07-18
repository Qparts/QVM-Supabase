-- add_rfq_item_inline is a shared public RPC: called by the web frontend (internal dashboard,
-- rfq-dashboard-v3) AND directly by external callers hitting the RPC endpoint. Only items added
-- from the web frontend should sync to the AppSheet sheet. Add p_from_frontend (default false, so
-- any caller that doesn't know about this new parameter — i.e. the external caller — gets no sheet
-- write), and have the two actual frontend call sites pass true.

CREATE OR REPLACE FUNCTION public.add_rfq_item_inline(
  p_quotation_id int,
  p_part_number text DEFAULT NULL,
  p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1,
  p_brand_class int DEFAULT NULL,
  p_part_photo text DEFAULT NULL,
  p_initial_note text DEFAULT NULL,
  p_from_frontend boolean DEFAULT false
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
  v_item_status int;
BEGIN
  v_item_status := CASE
    WHEN p_part_number IS NOT NULL AND btrim(p_part_number) <> '' THEN 235
    ELSE 236
  END;
  SELECT order_number INTO v_order_number
  FROM qvm_new_apps.quotations
  WHERE quotation_id = p_quotation_id;

  IF v_order_number IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Invalid quotation_id','quotation_item_id', NULL);
  END IF;

  -- Compute next item index per quotation based on existing line_item_code suffix; fallback to count+1
  SELECT COALESCE(
    MAX(
      NULLIF(regexp_replace(COALESCE(line_item_code, ''), '^.*-([0-9]+)$', '\1'), '')::int
    ), 0
  ) + 1
  INTO v_next_index
  FROM qvm_new_apps.quotation_items
  WHERE quotation_id = p_quotation_id;

  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    part_description,
    part_number,
    quantity,
    brand_class,
    part_photo,
    item_status,
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
    v_item_status,
    NOW(),
    NOW(),
    v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  -- Optional: attach initial note if provided (ignore failure if RPC not present)
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
      -- ignore if function not available
      NULL;
    END;
  END IF;

  SELECT list_data INTO v_brand_class_name FROM qvm_new_apps.list_data WHERE list_data_id = p_brand_class;

  -- Only items added from the web frontend sync to the sheet; external callers don't set this flag.
  IF p_from_frontend THEN
    BEGIN
      PERFORM net.http_post(
        url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet',
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body    := jsonb_build_object('quotation_item_id', v_item_id, 'quotation_id', p_quotation_id)
      );
    EXCEPTION WHEN others THEN
      -- Don't fail the item creation if the sheet write fails
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'message','Item added',
    'quotation_item_id', v_item_id,
    'item_status_id', v_item_status,
    'brand_class_id', p_brand_class,
    'brand_class', v_brand_class_name
  );
END;
$function$;
