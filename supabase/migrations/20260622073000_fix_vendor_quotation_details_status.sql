CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
    v_result JSON;
    v_quotation_vendor_id BIGINT;
    v_vendor_status INT;
BEGIN
    -- Get the vendor-specific header data
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
                                        'cost_id', qvi.cost_id,
                                        'cost', qvi.cost,
                                        'vendor_id', qvi.vendor_id,
                                        'vendor_item_status', qvi.vendor_item_status,
                                        'discount_percent', qvi.discount_percent,
                                        'sla', qvi.sla,
                                        'best_cost', qvi.best_cost,
                                        'available_quantity', qvi.available_quantity,
                                        'quotation_vendor_id', qvi.quotation_vendor_id,
                                        'available_brand_class', qvi.available_brand_class,
                                        'alternative_part_number', qvi.alternative_part_number,
                                        'created_at', qvi.created_at,
                                        'updated_at', qvi.updated_at,
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
                                              AND n.type_id = qvi.cost_id
                                              AND n.is_internal = FALSE
                                        )
                                    )
                                ),
                                '[]'::json
                            )
                            FROM qvm_new_apps.quotation_vendor_items qvi
                            WHERE qvi.quotation_item_id = qi.quotation_item_id
                              AND qvi.vendor_id = p_vendor_id
                        )
                    )
                )
                FROM qvm_new_apps.quotation_items qi
                LEFT JOIN qvm_new_apps.list_data main_brand_ld
                       ON qi.main_brand = main_brand_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data brand_class_ld
                       ON qi.brand_class = brand_class_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data part_category_ld
                       ON qi.part_category = part_category_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data item_status_ld
                       ON qi.item_status = item_status_ld.list_data_id
                WHERE qi.quotation_id = p_quotation_id
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;$function$
;
