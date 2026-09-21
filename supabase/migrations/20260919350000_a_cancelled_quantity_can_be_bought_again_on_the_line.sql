-- A cancelled quantity can be bought again on the same line.
--
-- Besides a new line, the desk may take another vendor's price already on the line and buy the
-- cancelled quantity from them there: the confirmed line gets the quantity back (a fully cancelled
-- line reopens as Confirmed), the other vendors' offers are unlocked again, and the purchase order
-- for that vendor follows through the ordinary create-PO path from the page.
ALTER TABLE qvm_new_apps.quotation_item_cancellations
  ADD COLUMN IF NOT EXISTS resolved_on_line boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS rebought_cost_id bigint;

CREATE OR REPLACE FUNCTION qvm_new_apps.rebuy_cancelled_quantity_on_line(p_cancellation_id bigint, p_cost_id bigint, p_quantity integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  c     qvm_new_apps.quotation_item_cancellations%ROWTYPE;
  v_ci  qvm_new_apps.confirmed_items%ROWTYPE;
  v_src qvm_new_apps.quotation_vendor_items%ROWTYPE;
  v_qty int; v_vendor_name text; v_status int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Internal users only');
  END IF;
  SELECT * INTO c FROM qvm_new_apps.quotation_item_cancellations WHERE cancellation_id = p_cancellation_id FOR UPDATE;
  IF c.cancellation_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'Cancellation not found');
  END IF;
  IF c.reissued_item_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'This quantity is already back on the order');
  END IF;
  SELECT * INTO v_ci FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = c.confirmed_item_id;
  IF v_ci.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'The confirmed line is gone — put the quantity back as a new line instead');
  END IF;
  SELECT * INTO v_src FROM qvm_new_apps.quotation_vendor_items WHERE cost_id = p_cost_id AND quotation_item_id = c.quotation_item_id;
  IF v_src.cost_id IS NULL OR COALESCE(v_src.cost, 0) <= 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'Pick one of the vendors who priced this line');
  END IF;
  IF c.vendor_id IS NOT NULL AND v_src.vendor_id = c.vendor_id THEN
    RETURN jsonb_build_object('status', false, 'message', 'That is the vendor who cancelled — pick another, or send the line again');
  END IF;
  v_qty := LEAST(GREATEST(COALESCE(p_quantity, c.qty), 1), c.qty);

  -- The line gets the quantity back. A full cancellation left approved_qty as it was and closed the
  -- line; it reopens as Confirmed. A partial one took the quantity off; it goes back on.
  IF v_ci.item_status = 18 THEN
    v_status := 19;
    UPDATE qvm_new_apps.confirmed_items
       SET item_status = 19, updated_by = v_uid, updated_at = now()
     WHERE confirmed_item_id = v_ci.confirmed_item_id;
    INSERT INTO qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by) VALUES (v_ci.confirmed_item_id, 19, v_uid);
  ELSE
    v_status := v_ci.item_status;
    UPDATE qvm_new_apps.confirmed_items
       SET approved_qty = COALESCE(approved_qty, 0) + v_qty, updated_by = v_uid, updated_at = now()
     WHERE confirmed_item_id = v_ci.confirmed_item_id;
  END IF;

  -- The other vendors' offers were marked cancelled with the line; they are offers again.
  UPDATE qvm_new_apps.quotation_vendor_items
     SET vendor_item_status = 158, updated_at = now()
   WHERE quotation_item_id = c.quotation_item_id
     AND vendor_item_status = 160
     AND cost IS NOT NULL
     AND (c.vendor_id IS NULL OR vendor_id <> c.vendor_id);

  -- The pick the purchase order is built from.
  UPDATE qvm_new_apps.quotation_items
     SET selected_cost_id = p_cost_id, updated_at = now()
   WHERE quotation_item_id = c.quotation_item_id;

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(v_ci.confirmed_item_id);

  SELECT vendor_name INTO v_vendor_name FROM qvm_new_apps.vendors WHERE vendor_id = v_src.vendor_id;

  UPDATE qvm_new_apps.quotation_item_cancellations
     SET reissued_item_id = c.quotation_item_id, reissued_at = now(), reissued_by = v_uid,
         resolved_on_line = true, rebought_cost_id = p_cost_id
   WHERE cancellation_id = p_cancellation_id;

  INSERT INTO qvm_new_apps.notes (note_type, type_id, user_id, is_internal, note_description)
  VALUES ('quotation_items', c.quotation_item_id, v_uid, true,
          format('%s of the cancelled quantity bought again on this line from %s', v_qty, COALESCE(v_vendor_name, 'another vendor')));

  RETURN jsonb_build_object('status', true, 'data', jsonb_build_object(
    'quotation_item_id', c.quotation_item_id, 'confirmed_item_id', v_ci.confirmed_item_id,
    'confirmed_order_id', v_ci.confirmed_order_id, 'quantity', v_qty, 'line_status', v_status,
    'cost_id', p_cost_id, 'quotation_vendor_id', v_src.quotation_vendor_id, 'vendor_id', v_src.vendor_id));
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.rebuy_cancelled_quantity_on_line(bigint, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.rebuy_cancelled_quantity_on_line(bigint, bigint, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.rebuy_cancelled_quantity_on_line(p_cancellation_id bigint, p_cost_id bigint, p_quantity integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT qvm_new_apps.rebuy_cancelled_quantity_on_line(p_cancellation_id, p_cost_id, p_quantity);
$function$;
GRANT EXECUTE ON FUNCTION public.rebuy_cancelled_quantity_on_line(bigint, bigint, integer) TO authenticated;

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
                -- Every alternative on the line, from every source, for the desk's one list.
                'item_alternatives', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
                             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
                             'part_number', a.part_number,
                             'brand_class_name', bc.list_data, 'brand_name', br.list_data,
                             'origin', COALESCE(oc.name_ar, oc.name_en),
                             'unit_price', a.unit_price, 'available_quantity', a.available_quantity, 'delivery_days', a.delivery_days,
                             'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
                             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
                      FROM qvm_new_apps.quotation_vendor_item_alternatives a
                      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                     WHERE a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb),
                -- How many of the line are already on purchase orders (cancelled purchase lines excluded).
                'ordered_qty', (SELECT COALESCE(SUM(pi.approved_qty), 0)::int
                                  FROM qvm_new_apps.purchase_items pi
                                  JOIN qvm_new_apps.quotation_vendor_items pq ON pq.cost_id = pi.cost_id
                                  LEFT JOIN qvm_new_apps.list_data pst ON pst.list_data_id = pi.vendor_item_status
                                 WHERE pq.quotation_item_id = qi.quotation_item_id
                                   AND COALESCE(pst.list_data, '') NOT ILIKE 'cancel%'),
                -- Every note on the line, internal ones included: this is the buying desk's page.
                -- A quantity cancelled after confirmation — by the vendor on the purchase order or by an
                -- approved request — and what the desk did about it. A line re-issued for such a quantity
                -- names the line it came from.
                'reissued_from_item_id', qi.reissued_from_item_id,
                'reissued_from_part_number', (SELECT p.part_number FROM qvm_new_apps.quotation_items p
                                               WHERE p.quotation_item_id = qi.reissued_from_item_id),
                'cancellations', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                             'cancellation_id', c.cancellation_id, 'qty', c.qty, 'source', c.source,
                             'vendor_id', c.vendor_id, 'vendor_name', cv.vendor_name,
                             'reason', crs.list_data, 'note', c.note, 'created_at', c.created_at,
                             'reissued_item_id', c.reissued_item_id, 'reissued_at', c.reissued_at,
                             'reissued_status', ri.item_status, 'resolved_on_line', c.resolved_on_line,
                             'rebought_vendor', (SELECT rv.vendor_name FROM qvm_new_apps.quotation_vendor_items rq JOIN qvm_new_apps.vendors rv ON rv.vendor_id = rq.vendor_id WHERE rq.cost_id = c.rebought_cost_id)) ORDER BY c.cancellation_id DESC)
                      FROM qvm_new_apps.quotation_item_cancellations c
                      LEFT JOIN qvm_new_apps.vendors cv ON cv.vendor_id = c.vendor_id
                      LEFT JOIN qvm_new_apps.list_data crs ON crs.list_data_id = c.reason_id
                      LEFT JOIN qvm_new_apps.quotation_items ri ON ri.quotation_item_id = c.reissued_item_id
                     WHERE c.quotation_item_id = qi.quotation_item_id), '[]'::jsonb),
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
                                         'source',             a.source,
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

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 39 $$;
