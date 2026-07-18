-- Synced from QVM/test branch applied migration history (version 20260629013128, name: revert_create_vendors_quotations_no_delete)

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendors_quotations(p_vendor_ids bigint[], p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$DECLARE
  v_vendor_id           BIGINT;
  v_quotation_vendor_id BIGINT;
  v_results             JSONB := '[]'::jsonb;
  rec                   JSONB;
  v_item_id             BIGINT;
  v_cost                NUMERIC;
  v_from_database       BOOLEAN;
  v_discount            NUMERIC;
  v_vendor_item_status  INTEGER;
  v_new_cost_id         BIGINT;
BEGIN
  IF p_vendor_ids IS NULL OR array_length(p_vendor_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_vendor_ids is empty');
  END IF;

  IF p_quotation_items IS NULL OR jsonb_typeof(p_quotation_items) <> 'array' OR jsonb_array_length(p_quotation_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_quotation_items must be a non-empty JSON array');
  END IF;

  FOREACH v_vendor_id IN ARRAY p_vendor_ids LOOP

    SELECT quotation_vendor_id
    INTO v_quotation_vendor_id
    FROM qvm_new_apps.quotation_vendors
    WHERE vendor_id = v_vendor_id
      AND quotation_id = p_quotation_id
    LIMIT 1;

    IF v_quotation_vendor_id IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
      VALUES (v_vendor_id, p_quotation_id, NOW())
      RETURNING quotation_vendor_id INTO v_quotation_vendor_id;
    END IF;

    FOR rec IN SELECT * FROM jsonb_array_elements(p_quotation_items) LOOP
      v_item_id            := (rec->>'quotation_item_id')::BIGINT;
      v_cost               := NULLIF(rec->>'cost','')::NUMERIC;
      v_discount           := NULLIF(rec->>'discount_percent','')::NUMERIC;
      v_from_database      := (rec->>'from_database')::BOOLEAN;
      v_vendor_item_status := (rec->>'vendor_item_status')::INTEGER;

      RAISE NOTICE 'Trying insert: item_id=%, vendor_id=%, quotation_vendor_id=%, cost=%, discount=%, from_database=%',
        v_item_id, v_vendor_id, v_quotation_vendor_id, v_cost, v_discount, v_from_database;

      WITH ins AS (
        INSERT INTO qvm_new_apps.quotation_vendor_items (
          quotation_item_id, vendor_id, quotation_vendor_id,
          best_cost, cost, discount_percent, from_database,
          vendor_item_status, created_at, updated_at
        )
        VALUES (
          v_item_id, v_vendor_id, v_quotation_vendor_id,
          FALSE, v_cost, v_discount, v_from_database,
          v_vendor_item_status, NOW(), NOW()
        )
        ON CONFLICT (quotation_item_id, vendor_id) DO UPDATE
        SET cost = EXCLUDED.cost,
            discount_percent = EXCLUDED.discount_percent,
            from_database = EXCLUDED.from_database,
            updated_at = NOW()
        RETURNING cost_id
      )
      SELECT cost_id INTO v_new_cost_id FROM ins;

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'quotation_vendor_id', v_quotation_vendor_id,
          'vendor_id', v_vendor_id,
          'quotation_id', p_quotation_id,
          'quotation_item_id', v_item_id,
          'cost_id', v_new_cost_id,
          'inserted', v_new_cost_id IS NOT NULL
        )
      );

    END LOOP;

  END LOOP;

  -- Update the quotation items to "Sent To Vendor" and log the transition
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  )
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 237,
      updated_at = now()
  FROM sent_items si
  WHERE qi.quotation_item_id = si.quotation_item_id;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT (log_rec->>'quotation_item_id')::bigint, 237, auth.uid(), now()
  FROM jsonb_array_elements(p_quotation_items) log_rec
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;$function$;
;
