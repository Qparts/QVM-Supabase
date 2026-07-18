-- Synced from QVM/test branch applied migration history (version 20260514072037, name: add_security_definer_to_status_counts)
-- Add SECURITY DEFINER to status_counts function to allow it to bypass RLS
CREATE OR REPLACE FUNCTION qvm_new_apps.status_counts(p_account_manager_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
      'status', 'success',
      'message', 'Status bar counts retrieved successfully',
      'data', jsonb_build_object(
          'new_rfqs',            COUNT(*) FILTER (WHERE qi.item_status = 15),
          'tendering_rfqs',      COUNT(*) FILTER (WHERE qi.item_status = 16),
          'priced_rfqs',         COUNT(*) FILTER (WHERE qi.item_status = 17),
          'confirmed_orders',    COUNT(*) FILTER (WHERE qi.item_status = 19),
          'delivered_orders',    COUNT(*) FILTER (WHERE ci.item_status = 23),
          'return_requests',     COUNT(*) FILTER (WHERE ci.item_status = 28),
          'awaiting_signature',  COUNT(*) FILTER (WHERE ci.item_status = 24),
          'missing_purchase_invoices',
              COUNT(DISTINCT co.confirmed_order_id)
              FILTER (
                WHERE po.confirmed_order_id IS NOT NULL
                AND ( po.vendor_invoice_url IS NULL
                OR po.vendor_invoice_url = '')
              )
      )
  )
  INTO v_result
  FROM qvm_new_apps.quotation_items qi
  JOIN qvm_new_apps.quotations q 
    ON q.quotation_id = qi.quotation_id
  LEFT JOIN qvm_new_apps.confirmed_items ci 
    ON ci.quotation_item_id = qi.quotation_item_id
  LEFT JOIN qvm_new_apps.confirmed_orders co 
    ON co.quotation_id = q.quotation_id
  LEFT JOIN qvm_new_apps.purchase_orders po 
    ON po.confirmed_order_id = co.confirmed_order_id
  WHERE (p_account_manager_ids IS NULL 
         OR q.account_manager_id = ANY(p_account_manager_ids));
  
  RETURN v_result;
END;$function$;;
