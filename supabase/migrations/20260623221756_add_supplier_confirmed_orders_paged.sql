-- Synced from QVM/test branch applied migration history (version 20260623221756, name: add_supplier_confirmed_orders_paged)

CREATE OR REPLACE FUNCTION public.get_supplier_confirmed_orders_paged(
    p_vendor_id integer,
    p_order_number text DEFAULT NULL,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 10
)
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
      AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%');

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
