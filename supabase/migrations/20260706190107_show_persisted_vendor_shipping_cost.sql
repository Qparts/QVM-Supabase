-- Synced from QVM/test branch applied migration history (version 20260706190107, name: show_persisted_vendor_shipping_cost)
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
;
