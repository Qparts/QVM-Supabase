-- Vendor-side agency price + discount + availability flow.
-- Adds a per-vendor agency_price on quotation_vendor_items and surfaces
-- agency_price / discount_percent / vendor_item_status to the internal pricing page.
-- All changes are additive and backward-compatible. Only the qvm_new_apps copies
-- are edited; the public.* wrappers for the bulk-update and pricing loaders just
-- delegate to these, so they pick up the change automatically.

BEGIN;

-- 1) Per-vendor agency (list) price on the vendor pricing row.
ALTER TABLE qvm_new_apps.quotation_vendor_items
  ADD COLUMN IF NOT EXISTS agency_price numeric;

-- 2) Bulk update: accept + persist agency_price alongside the existing fields.
CREATE OR REPLACE FUNCTION qvm_new_apps.update_quotation_vendor_items_bulk(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  updated jsonb;
  not_found jsonb;
BEGIN
  WITH changes AS (
    SELECT
      (x->>'cost_id')::int                                      AS cost_id,
      x->>'alternative_part_number'                             AS alternative_part_number,
      NULLIF(x->>'available_brand_class','')::int               AS available_brand_class,
      NULLIF(x->>'available_quantity','')::int                  AS available_quantity,
      NULLIF(x->>'cost','')::numeric                            AS cost,
      NULLIF(x->>'sla','')                                      AS sla,
      NULLIF(x->>'discount_percent','')::numeric               AS discount_percent,
      NULLIF(x->>'agency_price','')::numeric                   AS agency_price,
      NULLIF(x->>'vendor_item_status','') ::int                AS vendor_item_status
    FROM jsonb_array_elements(p_items) AS x
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_vendor_items qvi
    SET
      alternative_part_number = COALESCE(c.alternative_part_number, qvi.alternative_part_number),
      available_brand_class   = COALESCE(c.available_brand_class, qvi.available_brand_class),
      available_quantity      = COALESCE(c.available_quantity, qvi.available_quantity),
      cost                    = COALESCE(c.cost, qvi.cost),
      sla                     = COALESCE(c.sla, qvi.sla),
      discount_percent        = COALESCE(c.discount_percent, qvi.discount_percent),
      agency_price            = COALESCE(c.agency_price, qvi.agency_price),
      vendor_item_status      = COALESCE(c.vendor_item_status, qvi.vendor_item_status),
      best_cost               = FALSE,
      updated_at              = NOW()
    FROM changes c
    WHERE qvi.cost_id = c.cost_id
    RETURNING qvi.cost_id,
              qvi.alternative_part_number,
              qvi.available_brand_class,
              qvi.available_quantity,
              qvi.cost,
              qvi.sla,
              qvi.discount_percent,
              qvi.agency_price,
              qvi.vendor_item_status,
              qvi.best_cost
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(upd.*)), '[]'::jsonb)
  INTO updated
  FROM upd;

  SELECT COALESCE(jsonb_agg(to_jsonb(c.*)), '[]'::jsonb)
  INTO not_found
  FROM (
    SELECT *
    FROM (
      SELECT
        (x->>'cost_id')::int            AS cost_id,
        x->>'alternative_part_number'   AS alternative_part_number,
        NULLIF(x->>'available_brand_class','')::int AS available_brand_class,
        NULLIF(x->>'available_quantity','')::int    AS available_quantity,
        NULLIF(x->>'cost','')::numeric  AS cost,
        NULLIF(x->>'sla','')  AS sla,
        NULLIF(x->>'discount_percent','')               AS discount_percent,
        NULLIF(x->>'agency_price','')                   AS agency_price,
        NULLIF(x->>'vendor_item_status','')      AS vendor_item_status
      FROM jsonb_array_elements(p_items) AS x
    ) c
    WHERE NOT EXISTS (
      SELECT 1 FROM qvm_new_apps.quotation_vendor_items q
      WHERE q.cost_id = c.cost_id
    )
  ) AS c;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0),
    'updated', updated,
    'not_found', not_found
  );
END;
$function$;

-- 3) Internal pricing loader: expose the vendor's agency_price, discount_percent
--    and the raw vendor_item_status id (so the UI can detect "not available" = 161).
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

-- 4) Vendor loader: expose the vendor's saved agency_price (discount_percent and
--    vendor_item_status are already returned).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_id BIGINT;
    v_vendor_status INT;
BEGIN
    SELECT qv.quotation_vendor_id, qv.vendor_status
    INTO v_quotation_vendor_id, v_vendor_status
    FROM qvm_new_apps.quotation_vendors qv
    WHERE qv.quotation_id = p_quotation_id
      AND qv.vendor_id = p_vendor_id
    LIMIT 1;

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_id,
            'vendor_status', v_vendor_status,
            'quotation', (
                SELECT jsonb_build_object(
                    'quotation_id', q.quotation_id,
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'account_manager', q.account_manager,
                    'created_at', q.created_at,
                    'updated_at', q.updated_at
                )
                FROM qvm_new_apps.quotations q
                WHERE q.quotation_id = p_quotation_id
            ),
            'items', (
                SELECT json_agg(
                    json_build_object(
                        'quotation_item_id', qi.quotation_item_id,
                        'vin', qi.vin,
                        'main_brand', qi.main_brand,
                        'main_brand_name', main_brand_ld.list_data,
                        'model', qi.model,
                        'part_description', qi.part_description,
                        'part_number', qi.part_number,
                        'quantity', qi.quantity,
                        'brand_class', qi.brand_class,
                        'brand_class_name', brand_class_ld.list_data,
                        'part_category', qi.part_category,
                        'part_category_name', part_category_ld.list_data,
                        'part_photo', qi.part_photo,
                        'item_status', qi.item_status,
                        'item_status_name', item_status_ld.list_data,
                        'alternative_part_number', qi.alternative_part_number,
                        'created_at', qi.created_at,
                        'updated_at', qi.updated_at,
                        'vendor_pricing', (
                            SELECT COALESCE(
                                json_agg(
                                    json_build_object(
                                        'cost_id', qvi2.cost_id,
                                        'cost', qvi2.cost,
                                        'vendor_id', qvi2.vendor_id,
                                        'vendor_item_status', qvi2.vendor_item_status,
                                        'discount_percent', qvi2.discount_percent,
                                        'agency_price', qvi2.agency_price,
                                        'sla', qvi2.sla,
                                        'best_cost', qvi2.best_cost,
                                        'available_quantity', qvi2.available_quantity,
                                        'quotation_vendor_id', qvi2.quotation_vendor_id,
                                        'available_brand_class', qvi2.available_brand_class,
                                        'alternative_part_number', qvi2.alternative_part_number,
                                        'created_at', qvi2.created_at,
                                        'updated_at', qvi2.updated_at,
                                        'item_notes', (
                                            SELECT json_agg(
                                                json_build_object(
                                                    'note_description', n.note_description,
                                                    'note_attachment', n.note_attachment,
                                                    'created_at', n.created_at,
                                                    'user_name', u.user_name
                                                )
                                                ORDER BY n.created_at DESC
                                            )
                                            FROM qvm_new_apps.notes n
                                            LEFT JOIN qvm_new_apps.user_data u
                                              ON u.user_id = n.user_id
                                            WHERE n.note_type = 'quotation_vendor_item'
                                              AND n.type_id = qvi2.cost_id
                                              AND n.is_internal = FALSE
                                        )
                                    )
                                ),
                                '[]'::json
                            )
                            FROM qvm_new_apps.quotation_vendor_items qvi2
                            WHERE qvi2.quotation_item_id = qi.quotation_item_id
                              AND qvi2.vendor_id = p_vendor_id
                        )
                    )
                )
                FROM qvm_new_apps.quotation_vendor_items qvi
                JOIN qvm_new_apps.quotation_items qi
                  ON qi.quotation_item_id = qvi.quotation_item_id
                LEFT JOIN qvm_new_apps.list_data main_brand_ld
                       ON qi.main_brand = main_brand_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data brand_class_ld
                       ON qi.brand_class = brand_class_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data part_category_ld
                       ON qi.part_category = part_category_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data item_status_ld
                       ON qi.item_status = item_status_ld.list_data_id
                WHERE qvi.vendor_id = p_vendor_id
                  AND qvi.quotation_vendor_id = v_quotation_vendor_id
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

COMMIT;
