-- The buyer confirms how many to order from a vendor.
--
-- A vendor's offer says how many they have; the buyer says how many to take. That number lives on
-- the vendor line, is set from the pricing page, becomes the confirmed item's approved quantity —
-- at confirmation, or at once when the line is already confirmed but not yet ordered — and so the
-- purchase order's quantity.
ALTER TABLE qvm_new_apps.quotation_vendor_items
  ADD COLUMN IF NOT EXISTS confirmed_quantity integer;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_confirmed_quantity(p_cost_id bigint, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_item bigint;
  v_qty  integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team confirms quantities';
  END IF;
  IF p_quantity IS NOT NULL AND p_quantity < 1 THEN
    RAISE EXCEPTION 'The confirmed quantity has to be at least 1';
  END IF;

  UPDATE qvm_new_apps.quotation_vendor_items
     SET confirmed_quantity = p_quantity, updated_at = now()
   WHERE cost_id = p_cost_id
  RETURNING quotation_item_id INTO v_item;
  IF v_item IS NULL THEN RAISE EXCEPTION 'Unknown vendor line'; END IF;

  -- A line already confirmed on this vendor but not yet ordered follows the new number.
  SELECT GREATEST(COALESCE(p_quantity, qi.quantity, 1), 1) INTO v_qty
    FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = v_item;
  UPDATE qvm_new_apps.confirmed_items ci
     SET approved_qty = v_qty, updated_at = now()
    FROM qvm_new_apps.quotation_items qi
   WHERE ci.quotation_item_id = v_item
     AND qi.quotation_item_id = v_item
     AND qi.selected_cost_id = p_cost_id
     AND qi.cost_id IS NULL;

  RETURN jsonb_build_object('status', 'success', 'quotation_item_id', v_item, 'confirmed_quantity', p_quantity);
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.set_vendor_confirmed_quantity(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.set_vendor_confirmed_quantity(bigint, integer) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.set_vendor_confirmed_quantity(p_cost_id bigint, p_quantity integer)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.set_vendor_confirmed_quantity(p_cost_id, p_quantity) $$;
REVOKE ALL ON FUNCTION public.set_vendor_confirmed_quantity(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_vendor_confirmed_quantity(bigint, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_vendor_pricings(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'status', true,
        'message', 'success',
        'data', jsonb_agg(
            jsonb_build_object(
                'quotation_item_id', qi.quotation_item_id,
                'quotation_id', qi.quotation_id,
                'shipping_price', q.shipping_price,
                'customer_id', qi.customer_id,
                'vin', qi.vin,
                'main_brand', lcd_mb.list_data,
                'model', qi.model,
                'part_description', qi.part_description,
                'part_number', qi.part_number,
                'quantity', qi.quantity,
                -- The class by NAME, as main_brand and part_category already are; the id rides beside it
                -- for anything that needs to write it back.
                'brand_class', lcd_bc.list_data,
                'brand_class_id', qi.brand_class,
                'part_photo', qi.part_photo,
                -- Every note on the line, internal ones included: this is the buying desk's page.
                'item_notes_count', (SELECT COUNT(*)::int FROM qvm_new_apps.notes n
                                      WHERE n.note_type = 'quotation_items' AND n.type_id = qi.quotation_item_id),
                'item_status', qi.item_status,
                'alternative_part_number', qi.alternative_part_number,
                'price_before_vat', qi.price_before_vat,
                'discount_percent', qi.discount_percent,
                'total_price_before_vat', qi.total_price_before_vat,
                'cost_id', qi.cost_id,
                'purchase_cost', qvi_pur.cost,
                'purchase_vendor', v_pur.vendor_name,
                'part_category', lcd_pc.list_data,
                'agency_price', qi.agency_price,
                'created_at', qi.created_at,
                'updated_at', qi.updated_at,
                'vendor_pricing', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'cost_id', qvi.cost_id,
                            'quotation_item_id', qvi.quotation_item_id,
                            'cost', qvi.cost,
                            'vendor_name', v.vendor_name,
                            'vendor_branch_id', qv.vendor_branch_id,
                            'vendor_branch_city', vb.city,
                            'vendor_branch_name', vb.branch_name,
                            'vendor_shipping_cost', (
                                SELECT pi.vendor_shipping_cost
                                FROM qvm_new_apps.purchase_items pi
                                WHERE pi.cost_id = qvi.cost_id
                                LIMIT 1
                            ),
                            'item_shipping', qvi.item_shipping,
                            'vendor_item_status', lcd_vis.list_data,
                            'vendor_item_status_id', qvi.vendor_item_status,
                            'discount_percent', qvi.discount_percent,
                            'agency_price', qvi.agency_price,
                            'from_database', qvi.from_database,
                            'sla', qvi.sla,
                            'best_cost', qvi.best_cost,
                            'available_quantity', qvi.available_quantity,
                            'confirmed_quantity', qvi.confirmed_quantity,
                            'quotation_vendor_id', qvi.quotation_vendor_id,
                            'available_brand_class', lcd_abc.list_data,
                            'alternative_part_number', qvi.alternative_part_number,
                            -- The alternatives this vendor offered on this line, and which one the
                            -- buyer chose to take instead of the part that was asked for. The
                            -- effective figures are what the purchase order and the approvals use.
                            'chosen_alternative_id', qvi.chosen_alternative_id,
                            'note', qvi.note,
                            'vendor_part_number', qvi.vendor_part_number,
                            'files', COALESCE(qvi.files, '[]'::jsonb),
                            'improvement_requested_at', qvi.improvement_requested_at,
                            'improvement_note', qvi.improvement_note,
                            'previous_cost', qvi.previous_cost,
                            'effective_cost', COALESCE(ch.unit_price, qvi.cost),
                            'effective_part_number', COALESCE(ch.part_number, qvi.vendor_part_number),
                            'alternatives', COALESCE((
                                SELECT jsonb_agg(jsonb_build_object(
                                         'alternative_id',     a.alternative_id,
                                         'part_number',        a.part_number,
                                         'brand_class_name',   bc.list_data,
                                         'brand_name',         br.list_data,
                                         'origin',             COALESCE(oc.name_ar, oc.name_en),
                                         'unit_price',         a.unit_price,
                                         'available_quantity', a.available_quantity,
                                         'delivery_days',      a.delivery_days,
                                         'note',               a.note,
                                         'photos',             a.photos,
                                         'visible_to_workshop', a.visible_to_workshop) ORDER BY a.alternative_id)
                                  FROM qvm_new_apps.quotation_vendor_item_alternatives a
                                  LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                                  LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                                  LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                                 WHERE a.cost_id = qvi.cost_id), '[]'::jsonb),
                            'created_at', qvi.created_at,
                            'updated_at', qvi.updated_at,
                            'is_best_price', (
                                qvi.cost = (
                                    SELECT MIN(cost)
                                    FROM qvm_new_apps.quotation_vendor_items
                                    WHERE quotation_item_id = qi.quotation_item_id
                                )
                            ),
                            'selling_price',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (1 + (pm.percentage)), 2)
                                    ELSE 0
                                END,
                            'profit_value',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (pm.percentage), 2)
                                    ELSE 0
                                END,
                            'profit_percentage',
                                COALESCE(pm.percentage, 0)
                        )
                    )
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    LEFT JOIN qvm_new_apps.list_data lcd_abc
                        ON qvi.available_brand_class = lcd_abc.list_data_id
                    LEFT JOIN qvm_new_apps.list_data lcd_vis
                        ON qvi.vendor_item_status = lcd_vis.list_data_id
                    LEFT JOIN qvm_new_apps.vendors v
                        ON qvi.vendor_id = v.vendor_id
                    LEFT JOIN qvm_new_apps.quotation_vendors qv
                        ON qv.quotation_vendor_id = qvi.quotation_vendor_id
                    LEFT JOIN qvm_new_apps.vendor_branches vb
                        ON vb.vendor_branch_id = qv.vendor_branch_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch
                        ON ch.alternative_id = qvi.chosen_alternative_id
                    LEFT JOIN qvm_new_apps.profit_categories pc
                        ON pc.brand_class = qi.brand_class
                       AND pc.part_category = qi.part_category
                    LEFT JOIN qvm_new_apps.cost_categories cc
                        ON qvi.cost >= (cc.cost_range->>0)::numeric
                        AND qvi.cost <  (cc.cost_range->>1)::numeric
                    LEFT JOIN qvm_new_apps.profit_margins pm
                        ON pm.profit_categories_id = pc.category_id
                        AND pm.cost_range_id = cc.cost_range_id
                  WHERE qvi.quotation_item_id = qi.quotation_item_id
                    AND (
                        cc.cost_range IS NULL
                        OR qvi.cost IS NULL
                        OR (
                            qvi.cost >= (cc.cost_range->>0)::numeric
                            AND qvi.cost <  (cc.cost_range->>1)::numeric
                        )
                    )
                )
            )
            ORDER BY qi.quotation_item_id DESC
        )
    )
    INTO result
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotations q ON qi.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data lcd_pc
           ON qi.part_category = lcd_pc.list_data_id
    LEFT JOIN qvm_new_apps.list_data lcd_mb
           ON qi.main_brand = lcd_mb.list_data_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_pur
           ON qvi_pur.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.vendors v_pur
           ON v_pur.vendor_id = qvi_pur.vendor_id
    LEFT JOIN qvm_new_apps.list_data lcd_bc ON lcd_bc.list_data_id = qi.brand_class
    WHERE q.order_number = p_order_number;

    RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_lines(p_quotation_id bigint, p_item_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_order bigint;
  v_n     integer := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_item_ids, ARRAY[]::bigint[])) id
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = id)
  ) THEN
    RETURN jsonb_build_object('confirmed', 0);
  END IF;

  SELECT co.confirmed_order_id INTO v_order
    FROM qvm_new_apps.confirmed_orders co WHERE co.quotation_id = p_quotation_id
   ORDER BY co.confirmed_order_id LIMIT 1;
  IF v_order IS NULL THEN
    INSERT INTO qvm_new_apps.confirmed_orders (quotation_id, created_at, updated_at)
    VALUES (p_quotation_id, clock_timestamp(), clock_timestamp())
    RETURNING confirmed_order_id INTO v_order;
  END IF;

  WITH ins AS (
    INSERT INTO qvm_new_apps.confirmed_items
      (confirmed_order_id, quotation_item_id, approved_qty, item_status, final_part_number, final_brand_class, created_at, updated_at)
    -- The quantity to order: what the buyer confirmed on the picked vendor's offer, else the requested.
    SELECT v_order, qi.quotation_item_id, GREATEST(COALESCE(sv.confirmed_quantity, qi.quantity, 1), 1), 19,
           COALESCE(ch.part_number, qi.alternative_part_number, qi.part_number),
           COALESCE(ch.brand_class, qi.brand_class),
           clock_timestamp(), clock_timestamp()
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.quotation_vendor_items sv ON sv.cost_id = qi.selected_cost_id
      LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = sv.chosen_alternative_id
     WHERE qi.quotation_id = p_quotation_id
       AND qi.quotation_item_id = ANY(p_item_ids)
       AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = qi.quotation_item_id)
    RETURNING quotation_item_id
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_items qi
       SET item_status = 19, updated_at = now()
     WHERE qi.quotation_item_id IN (SELECT quotation_item_id FROM ins)
    RETURNING qi.quotation_item_id
  ),
  logged AS (
    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
    SELECT quotation_item_id, 19, auth.uid() FROM upd
    RETURNING quotation_item_id
  )
  SELECT count(*) INTO v_n FROM ins;

  RETURN jsonb_build_object('confirmed', v_n, 'confirmed_order_id', v_order);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 15 $$;
