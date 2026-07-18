-- Synced from QVM/test branch applied migration history (version 20260317102256, name: create_overall_order_summary_function)
BEGIN;

CREATE OR REPLACE FUNCTION public.get_overall_order_summary(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH
  user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id, first_branch.customer_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  per_order AS (
    SELECT
      os.confirmed_order_id,
      BOOL_OR(ci.item_status = 19) AS any_confirmed,
      BOOL_OR(ci.item_status = 23) AS any_delivered,
      BOOL_OR(ci.item_status = 28) AS any_return_requests,
      BOOL_OR(ci.item_status = 24) AS any_cancellation_requests,
      BOOL_OR(ci.item_status = 21) AS any_processing
    FROM order_scope os
    LEFT JOIN qvm_new_apps.confirmed_items ci
      ON ci.confirmed_order_id = os.confirmed_order_id
    GROUP BY os.confirmed_order_id
  ),
  po_missing AS (
    SELECT DISTINCT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = os.confirmed_order_id
    WHERE
      (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
  ),
  rfq_scope AS (
    SELECT DISTINCT q.quotation_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  rfq_items AS (
    SELECT qi.quotation_id, qi.item_status
    FROM qvm_new_apps.quotation_items qi
    JOIN rfq_scope rs ON rs.quotation_id = qi.quotation_id
  ),
  rfq_counts AS (
    SELECT
      COUNT(DISTINCT CASE WHEN item_status = 15 THEN quotation_id END) AS new_rfq,
      COUNT(DISTINCT CASE WHEN item_status = 16 THEN quotation_id END) AS processing_rfq,
      COUNT(DISTINCT CASE WHEN item_status = 17 THEN quotation_id END) AS priced
    FROM rfq_items
  ),
  order_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE any_confirmed) AS confirmed,
      COUNT(*) FILTER (WHERE any_delivered) AS delivered,
      COUNT(*) FILTER (WHERE any_return_requests) AS return_requests,
      COUNT(*) FILTER (WHERE any_cancellation_requests) AS cancellation_requests,
      COUNT(*) FILTER (WHERE any_processing) AS processing_order
    FROM per_order
  ),
  missing_po AS (
    SELECT COUNT(*) AS missing_purchase_invoices
    FROM po_missing
  )
  SELECT jsonb_build_object(
    'new_rfq', coalesce((SELECT new_rfq FROM rfq_counts),0),
    'processing', coalesce((SELECT processing_rfq FROM rfq_counts),0) + coalesce((SELECT processing_order FROM order_counts),0),
    'priced', coalesce((SELECT priced FROM rfq_counts),0),
    'confirmed', coalesce((SELECT confirmed FROM order_counts),0),
    'delivered', coalesce((SELECT delivered FROM order_counts),0),
    'return_requests', coalesce((SELECT return_requests FROM order_counts),0),
    'cancellation_requests', coalesce((SELECT cancellation_requests FROM order_counts),0),
    'missing_purchase_invoices', coalesce((SELECT missing_purchase_invoices FROM missing_po),0)
  );
$$;

REVOKE ALL ON FUNCTION public.get_overall_order_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_overall_order_summary(uuid) TO authenticated;

COMMIT;;
