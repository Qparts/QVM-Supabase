-- Purchases Performance Reports tab: monthly Purchase Orders vs. Uploaded Invoices over the last 6
-- months, matching the "أوامر الشراء مقابل الفواتير المرفوعة" reference design (and the equivalent
-- demo chart already in the legacy Suppliers Reports tab, now built on real data). This is a fixed
-- trailing-6-month window, independent of the tab's Date From/To filter (which stays available for
-- the other blocks) — only the branch filter applies here, since "last 6 months" is the report's own
-- defined scope.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_monthly_po_vs_invoice_report(
  p_branch_id integer DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  WITH months AS (
    SELECT date_trunc('month', now()) - (n || ' months')::interval AS month_start
    FROM generate_series(0, 5) AS n
  ),
  scoped_items AS (
    SELECT DISTINCT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    WHERE (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  scoped_pos AS (
    SELECT DISTINCT po.purchase_order_id, date_trunc('month', po.created_at) AS month_start
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
  ),
  scoped_invoices AS (
    SELECT DISTINCT pia.attachment_id, date_trunc('month', pia.uploaded_at) AS month_start
    FROM qvm_new_apps.purchase_invoice_attachments pia
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = pia.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN scoped_items si ON si.quotation_item_id = ci.quotation_item_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_agg(to_jsonb(r) ORDER BY r.month_start)
  ) INTO v_result
  FROM (
    SELECT
      to_char(m.month_start, 'YYYY-MM') AS month_key,
      COALESCE((SELECT count(*) FROM scoped_pos sp WHERE sp.month_start = m.month_start), 0) AS po_count,
      COALESCE((SELECT count(*) FROM scoped_invoices si2 WHERE si2.month_start = m.month_start), 0) AS invoice_count,
      m.month_start
    FROM months m
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_monthly_po_vs_invoice_report(integer) TO authenticated;
