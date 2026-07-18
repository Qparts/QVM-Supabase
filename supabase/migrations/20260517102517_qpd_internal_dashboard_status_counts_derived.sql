-- Synced from QVM/test branch applied migration history (version 20260517102517, name: qpd_internal_dashboard_status_counts_derived)
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
  effective_item_statuses AS (
    SELECT
      sq.quotation_id,
      sq.confirmed_order_id,
      array_agg(
        lower(trim(coalesce(ldc.list_data, ldq.list_data)))
        ORDER BY qi.quotation_item_id
      ) FILTER (WHERE coalesce(ldc.list_data, ldq.list_data) IS NOT NULL) AS statuses
    FROM scoped_quotations sq
    JOIN qvm_new_apps.quotation_items qi
      ON qi.quotation_id = sq.quotation_id
    LEFT JOIN qvm_new_apps.confirmed_items ci
      ON ci.quotation_item_id = qi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ldq
      ON ldq.list_data_id = qi.item_status
    LEFT JOIN qvm_new_apps.list_data ldc
      ON ldc.list_data_id = ci.item_status
    GROUP BY sq.quotation_id, sq.confirmed_order_id
  ),
  derived_statuses AS (
    SELECT
      eis.quotation_id,
      eis.confirmed_order_id,
      CASE
        WHEN eis.confirmed_order_id IS NULL THEN
          CASE
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%confirmed%') THEN 19
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%priced%') THEN 17
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%tendering%') THEN 16
            WHEN NOT EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status NOT LIKE '%unavailable%') THEN 20
            WHEN NOT EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status NOT LIKE '%canceled%') THEN 18
            WHEN NOT EXISTS (
              SELECT 1
              FROM unnest(eis.statuses) AS s(status)
              WHERE status NOT LIKE '%canceled%'
                AND status NOT LIKE '%unavailable%'
            ) THEN 20
            ELSE 15
          END
        ELSE
          CASE
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%return request%') THEN 28
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%cancellation request%') THEN 24
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%settled%') THEN 31
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%claim sent%') THEN 27
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%credit note issued%') THEN 30
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%invoice issued%') THEN 26
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%pending credit note%') THEN 215
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%pending invoice%') THEN 25
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%rn sign pending%') THEN 214
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%dn sign pending%') THEN 213
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%delivered%') THEN 23
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%out for delivery%') THEN 22
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%processing%') THEN 21
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%confirmed%') THEN 19
            WHEN EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status LIKE '%return%') THEN 29
            WHEN NOT EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status NOT LIKE '%canceled%') THEN 18
            WHEN NOT EXISTS (SELECT 1 FROM unnest(eis.statuses) AS s(status) WHERE status NOT LIKE '%unavailable%') THEN 20
            ELSE NULL
          END
      END AS derived_status_id
    FROM effective_item_statuses eis
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
      'new_rfqs', COUNT(*) FILTER (WHERE derived_status_id = 15 AND confirmed_order_id IS NULL),
      'tendering_rfqs', COUNT(*) FILTER (WHERE derived_status_id = 16 AND confirmed_order_id IS NULL),
      'priced_rfqs', COUNT(*) FILTER (WHERE derived_status_id = 17 AND confirmed_order_id IS NULL),
      'confirmed_orders', COUNT(*) FILTER (WHERE derived_status_id = 19 AND confirmed_order_id IS NOT NULL),
      'delivered_orders', COUNT(*) FILTER (WHERE derived_status_id = 23 AND confirmed_order_id IS NOT NULL),
      'return_requests', COUNT(*) FILTER (WHERE derived_status_id = 28 AND confirmed_order_id IS NOT NULL),
      'cancellation_requests', COUNT(*) FILTER (WHERE derived_status_id = 24 AND confirmed_order_id IS NOT NULL),
      'missing_purchase_invoices', (SELECT count_missing FROM missing_purchase_invoices)
    )
  )
  INTO v_result
  FROM derived_statuses;

  RETURN v_result;
END;
$function$;;
