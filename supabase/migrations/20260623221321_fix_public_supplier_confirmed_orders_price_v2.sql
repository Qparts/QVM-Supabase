-- Synced from QVM/test branch applied migration history (version 20260623221321, name: fix_public_supplier_confirmed_orders_price_v2)

DROP FUNCTION IF EXISTS public.get_supplier_confirmed_orders(integer);

CREATE FUNCTION public.get_supplier_confirmed_orders(p_vendor_id integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'status', 'success',
        'message', 'Purchase orders fetched successfully',
        'data', COALESCE(json_agg(
            json_build_object(
                'purchase_order_id', po.purchase_order_id,
                'confirmed_order_id', po.confirmed_order_id,
                'quotation_id', co.quotation_id,
                'vendor_status', po.vendor_status,
                'vendor_status_name', vendor_status_ld.list_data,
                'vendor_invoice_url', po.vendor_invoice_url,
                'vendor_invoice_number', po.vendor_invoice_number,
                'vendor_return_url', po.vendor_return_url,
                'uploaded_by', po.uploaded_by,
                'created_at', po.created_at,
                'updated_at', co.updated_at,
                'vendor', json_build_object(
                    'vendor_id', v.vendor_id,
                    'vendor_name', v.vendor_name
                ),
                'quotation', json_build_object(
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'delivery_type_name', dt_ld.list_data,
                    'account_manager', q.account_manager
                ),
                'items', (
                    SELECT json_agg(
                        json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'vin_numbers', (
                                SELECT json_agg(DISTINCT qi.vin)
                                FROM qvm_new_apps.quotation_items qi
                                WHERE qi.quotation_id = q.quotation_id
                            ),
                            'main_brands', (
                                SELECT json_agg(DISTINCT ld.list_data)
                                FROM qvm_new_apps.quotation_items qi2
                                LEFT JOIN qvm_new_apps.list_data ld
                                  ON ld.list_data_id = qi2.main_brand
                                WHERE qi2.quotation_id = q.quotation_id
                            ),
                            'models', (
                                SELECT json_agg(DISTINCT qi3.model)
                                FROM qvm_new_apps.quotation_items qi3
                                WHERE qi3.quotation_id = q.quotation_id
                            ),
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_description', qi_item.part_description,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'approved_qty', pi.approved_qty,
                            'item_status', ci.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'return_type', ci.return_type,
                            'return_type_name', return_type_ld.list_data,
                            'final_purchase_price', COALESCE(
                                NULLIF(pi.final_purchase_price, 0),
                                qvi.cost
                            ),
                            'total_quotation_price', (
                                SELECT COALESCE(SUM(
                                    COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                                ), 0)
                                FROM qvm_new_apps.purchase_items pi_sub
                                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                                  ON pi_sub.cost_id = qvi_sub.cost_id
                                WHERE pi_sub.purchase_order_id = po.purchase_order_id
                            ),
                            'number_of_parts', (
                                SELECT COUNT(*)
                                FROM qvm_new_apps.purchase_items pi2
                                WHERE pi2.purchase_order_id = po.purchase_order_id
                            ),
                            'recieved_qty', pi.received_qty,
                            'vendor_item_status', pi.vendor_item_status
                        )
                    )
                    FROM qvm_new_apps.purchase_items pi
                    JOIN qvm_new_apps.confirmed_items ci
                      ON pi.confirmed_item_id = ci.confirmed_item_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi
                      ON pi.cost_id = qvi.cost_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld
                      ON ci.item_status = item_status_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data return_type_ld
                      ON ci.return_type = return_type_ld.list_data_id
                    LEFT JOIN qvm_new_apps.quotation_items qi_item
                      ON ci.quotation_item_id = qi_item.quotation_item_id
                    WHERE pi.purchase_order_id = po.purchase_order_id
                )
            )
        ), '[]'::json)
    )
    INTO v_result
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.vendors v
      ON po.vendor_id = v.vendor_id
    JOIN qvm_new_apps.confirmed_orders co
      ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q
      ON co.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data vendor_status_ld
      ON po.vendor_status = vendor_status_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data dt_ld
      ON q.delivery_type = dt_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data ot_ld
      ON q.order_type = ot_ld.list_data_id
    WHERE po.vendor_id = p_vendor_id;

    RETURN v_result;
END;$function$;
;
