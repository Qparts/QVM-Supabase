-- Synced from QVM/test branch applied migration history (version 20260517103802, name: qpd_internal_dashboard_status_counts_item_level)
CREATE OR REPLACE FUNCTION qvm_new_apps.status_counts(p_account_manager_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH scoped_quotations AS (
    SELECT DISTINCT
      q.quotation_id,
      co.confirmed_order_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.confirmed_orders co
      ON co.quotation_id = q.quotation_id
    WHERE
      p_account_manager_ids IS NULL
      OR array_length(p_account_manager_ids, 1) IS NULL
      OR q.account_manager = ANY(p_account_manager_ids)
      OR EXISTS (
        SELECT 1
        FROM qvm_new_apps.quotation_account_managers qam
        WHERE qam.quotation_id = q.quotation_id
          AND (
            qam.assigned_from = ANY(p_account_manager_ids)
            OR qam.assigned_to = ANY(p_account_manager_ids)
          )
      )
  ),
  scoped_items AS (
    SELECT
      sq.quotation_id,
      sq.confirmed_order_id,
      COALESCE(ci.item_status, qi.item_status) AS effective_item_status
    FROM scoped_quotations sq
    JOIN qvm_new_apps.quotation_items qi
      ON qi.quotation_id = sq.quotation_id
    LEFT JOIN qvm_new_apps.confirmed_items ci
      ON ci.quotation_item_id = qi.quotation_item_id
  ),
  missing_purchase_invoices AS (
    SELECT COUNT(DISTINCT sq.confirmed_order_id) AS count_missing
    FROM scoped_quotations sq
    JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = sq.confirmed_order_id
    WHERE sq.confirmed_order_id IS NOT NULL
      AND (
        po.vendor_invoice_url IS NULL
        OR po.vendor_invoice_url = ''
      )
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Status bar counts retrieved successfully',
    'data', jsonb_build_object(
      'new_rfqs', COUNT(*) FILTER (WHERE effective_item_status = 15 AND confirmed_order_id IS NULL),
      'tendering_rfqs', COUNT(*) FILTER (WHERE effective_item_status = 16 AND confirmed_order_id IS NULL),
      'priced_rfqs', COUNT(*) FILTER (WHERE effective_item_status = 17 AND confirmed_order_id IS NULL),
      'confirmed_orders', COUNT(*) FILTER (WHERE effective_item_status = 19 AND confirmed_order_id IS NOT NULL),
      'delivered_orders', COUNT(*) FILTER (WHERE effective_item_status = 23 AND confirmed_order_id IS NOT NULL),
      'return_requests', COUNT(*) FILTER (WHERE effective_item_status = 28 AND confirmed_order_id IS NOT NULL),
      'cancellation_requests', COUNT(*) FILTER (WHERE effective_item_status = 24 AND confirmed_order_id IS NOT NULL),
      'missing_purchase_invoices', (SELECT count_missing FROM missing_purchase_invoices)
    )
  )
  INTO v_result
  FROM scoped_items;

  RETURN v_result;
END;
$function$;;
