-- Synced from QVM/test branch applied migration history (version 20260717210852, name: qnew_vendor_add_item_drop_onconflict)

CREATE OR REPLACE FUNCTION public.add_quotation_item_by_vendor(
  p_quotation_id int,
  p_part_number text DEFAULT NULL,
  p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1,
  p_brand_class int DEFAULT NULL,
  p_cost numeric DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_vendor bigint;
  v_utype text;
  v_qv_id bigint;
  v_status_added int;
  v_order_number text;
  v_next_index int;
  v_line_item_code text;
  v_item_id bigint;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Not authenticated');
  END IF;

  SELECT ud.user_vendor, ud.user_type::text INTO v_vendor, v_utype
  FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_user;
  IF v_vendor IS NULL OR v_utype <> '205' THEN
    RETURN jsonb_build_object('status','error','message','Only vendor users can add items');
  END IF;

  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;
  IF v_order_number IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Invalid quotation_id');
  END IF;

  SELECT quotation_vendor_id INTO v_qv_id
  FROM qvm_new_apps.quotation_vendors
  WHERE quotation_id = p_quotation_id AND vendor_id = v_vendor LIMIT 1;
  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
    VALUES (v_vendor, p_quotation_id, now()) RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  SELECT list_data_id INTO v_status_added
  FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(line_item_code,''),'^.*-([0-9]+)$','\1'),'')::int),0) + 1
  INTO v_next_index FROM qvm_new_apps.quotation_items WHERE quotation_id = p_quotation_id;
  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id, part_description, part_number, quantity, brand_class,
    item_status, created_by, created_at, updated_at, line_item_code
  ) VALUES (
    p_quotation_id, NULLIF(p_part_description,''), NULLIF(p_part_number,''),
    COALESCE(p_quantity,1), p_brand_class, v_status_added, v_user, now(), now(), v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  INSERT INTO qvm_new_apps.quotation_vendor_items (
    quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost,
    from_database, vendor_item_status, created_at, updated_at
  ) VALUES (
    v_item_id, v_vendor, v_qv_id, false, p_cost, false, NULL, now(), now()
  );

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items', p_type_id := v_item_id,
        p_note_description := p_note, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','quotation_item_id', v_item_id, 'line_item_code', v_line_item_code);
END;
$$;
;
