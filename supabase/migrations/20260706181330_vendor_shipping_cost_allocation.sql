-- Synced from QVM/test branch applied migration history (version 20260706181330, name: vendor_shipping_cost_allocation)
-- Vendor-branch shipping cost allocation in the Pricing page.
-- - purchase_items.vendor_shipping_cost: per-item allocated share of a vendor-branch's shipping,
--   set at PO-creation time (distinct from the unrelated client-facing quotations.shipping_price).
-- - get_quotation_vendor_pricings: now returns vendor_branch_id/city/name per vendor_pricing entry
--   so the Pricing page can group by branch before a PO is even created.
-- - create_purchase_orders_anditems: persists the per-item shipping share.
-- - get_supplier_confirmed_orders(_paged): expose total_shipping/total_with_shipping downstream.

-- 1. Schema ---------------------------------------------------------------------------------

ALTER TABLE qvm_new_apps.purchase_items
  ADD COLUMN vendor_shipping_cost double precision NOT NULL DEFAULT 0;

-- 2. get_quotation_vendor_pricings: branch info per vendor_pricing entry --------------------

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
                'brand_class', qi.brand_class,
                'part_photo', qi.part_photo,
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
                            'item_shipping', qvi.item_shipping,
                            'vendor_item_status', lcd_vis.list_data,
                            'vendor_item_status_id', qvi.vendor_item_status,
                            'discount_percent', qvi.discount_percent,
                            'agency_price', qvi.agency_price,
                            'from_database', qvi.from_database,
                            'sla', qvi.sla,
                            'best_cost', qvi.best_cost,
                            'available_quantity', qvi.available_quantity,
                            'quotation_vendor_id', qvi.quotation_vendor_id,
                            'available_brand_class', lcd_abc.list_data,
                            'alternative_part_number', qvi.alternative_part_number,
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
    WHERE q.order_number = p_order_number;

    RETURN result;
END;
$function$;

-- 3. create_purchase_orders_anditems: persist per-item shipping share ------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id, cost_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
    RETURNING ci.confirmed_item_id, ci.quotation_item_id
  ),
  -- Save cost_id back to quotation_items so it can be restored when reopening pricing modal
  cost_id_update AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET cost_id = ii.cost_id, updated_at = NOW()
    FROM inserted_items ii
    JOIN status_update su ON su.confirmed_item_id = ii.confirmed_item_id
    WHERE qi.quotation_item_id = su.quotation_item_id
      AND ii.cost_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id
  JOIN status_update su ON su.confirmed_item_id = pi.confirmed_item_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

-- Mirror into the public sibling copy (independent duplicate, not a wrapper) for consistency,
-- catching it up with vendor_branch_id (added in an earlier migration only to the qvm_new_apps
-- copy) plus the new shipping column.
CREATE OR REPLACE FUNCTION public.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

-- 4. Downstream totals: expose total_shipping / total_with_shipping alongside total_price ----

CREATE OR REPLACE FUNCTION public.get_supplier_confirmed_orders_paged(p_vendor_id integer, p_order_number text DEFAULT NULL::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_result JSON;
    v_offset integer := (p_page - 1) * p_page_size;
    v_total integer;
BEGIN
    SELECT COUNT(DISTINCT po.purchase_order_id)
    INTO v_total
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
    WHERE po.vendor_id = p_vendor_id
      AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
      AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids));

    SELECT json_build_object(
        'status', 'success',
        'total', v_total,
        'page', p_page,
        'page_size', p_page_size,
        'data', COALESCE((
            SELECT json_agg(po_row)
            FROM (
                SELECT json_build_object(
                    'purchase_order_id', po.purchase_order_id,
                    'confirmed_order_id', po.confirmed_order_id,
                    'quotation_id', co.quotation_id,
                    'vendor_status', po.vendor_status,
                    'vendor_status_name', vendor_status_ld.list_data,
                    'vendor_invoice_url', po.vendor_invoice_url,
                    'vendor_invoice_number', po.vendor_invoice_number,
                    'created_at', po.created_at,
                    'vendor', json_build_object(
                        'vendor_id', v.vendor_id,
                        'vendor_name', v.vendor_name
                    ),
                    'quotation', json_build_object(
                        'order_number', q.order_number,
                        'plate_number', q.plate_number,
                        'delivery_type_name', dt_ld.list_data,
                        'account_manager', q.account_manager
                    ),
                    'total_price', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                        ), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                          ON pi_sub.cost_id = qvi_sub.cost_id
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_shipping', (
                        SELECT COALESCE(SUM(pi_sub.vendor_shipping_cost), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_with_shipping', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                            + pi_sub.vendor_shipping_cost
                        ), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                          ON pi_sub.cost_id = qvi_sub.cost_id
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_qty', (
                        SELECT COALESCE(SUM(pi_sub.approved_qty), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'items', (
                        SELECT json_agg(json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'part_description', qi_item.part_description,
                            'approved_qty', pi.approved_qty,
                            'unit_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost),
                            'total_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost, 0) * pi.approved_qty,
                            'vendor_shipping_cost', pi.vendor_shipping_cost,
                            'item_status_name', item_status_ld.list_data,
                            'vendor_item_status', pi.vendor_item_status
                        ))
                        FROM qvm_new_apps.purchase_items pi
                        JOIN qvm_new_apps.confirmed_items ci ON pi.confirmed_item_id = ci.confirmed_item_id
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON pi.cost_id = qvi.cost_id
                        LEFT JOIN qvm_new_apps.list_data item_status_ld ON ci.item_status = item_status_ld.list_data_id
                        LEFT JOIN qvm_new_apps.quotation_items qi_item ON ci.quotation_item_id = qi_item.quotation_item_id
                        WHERE pi.purchase_order_id = po.purchase_order_id
                    )
                ) AS po_row
                FROM qvm_new_apps.purchase_orders po
                JOIN qvm_new_apps.vendors v ON po.vendor_id = v.vendor_id
                JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
                LEFT JOIN qvm_new_apps.list_data vendor_status_ld ON po.vendor_status = vendor_status_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data dt_ld ON q.delivery_type = dt_ld.list_data_id
                WHERE po.vendor_id = p_vendor_id
                  AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
                  AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids))
                ORDER BY po.created_at DESC
                LIMIT p_page_size OFFSET v_offset
            ) sub
        ), '[]'::json)
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;
;
