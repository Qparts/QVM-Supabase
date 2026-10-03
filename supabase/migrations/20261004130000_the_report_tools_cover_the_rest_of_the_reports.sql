-- The report tools cover the rest of the reports.
--
-- Seventeen more questions, each a query written here and scoped like the first nine: the
-- delivery pipeline and lead time, orders by delivery and order type, the purchase cycle and the
-- supplier invoice lag, invoicing status and invoice aging, sales against cost (per branch and
-- over time), cancellations, vendor fill and win rates and price rank, the desk's extraction and
-- tendering turnaround, a branch overview, a monthly summary, and stock coverage. Approvals and
-- shipments wait until their tables exist on every environment.

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_tool(p_tool text, p_params jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company integer := qvm_new_apps.ai_caller_company();
  v_scope integer[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
  -- An empty list means every branch the user may see, the same as no list at all.
  v_branches integer[] := CASE WHEN jsonb_typeof(p_params->'branch_ids') = 'array'
                                 THEN NULLIF(ARRAY(SELECT (x)::integer FROM jsonb_array_elements_text(p_params->'branch_ids') x), ARRAY[]::integer[]) END;
  v_limit integer := LEAST(GREATEST(COALESCE(NULLIF(p_params->>'limit', '')::integer, 50), 1), 200);
  v_bucket text := CASE WHEN COALESCE(p_params->>'bucket', 'week') IN ('day', 'week', 'month') THEN COALESCE(p_params->>'bucket', 'week') ELSE 'week' END;
  r record;
  v_rows jsonb;
  v_columns jsonb;
BEGIN
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN p_params := '{}'::jsonb; END IF;
  SELECT * INTO r FROM qvm_new_apps.ai_report_range(p_params);

  -- Every tool reads from the same scope: the caller's company's orders, within the caller's
  -- branch scope and the branches asked for, in the range.
  IF to_regclass('pg_temp.ai_scope') IS NOT NULL THEN DROP TABLE ai_scope; END IF;
  CREATE TEMP TABLE ai_scope (quotation_id integer, branch_id integer, branch_name text, created_at timestamptz) ON COMMIT DROP;
  INSERT INTO ai_scope
  SELECT q.quotation_id, cb.customer_id, cb.branch_name, q.created_at
    FROM qvm_new_apps.quotations q
    JOIN LATERAL (SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id LIMIT 1) f ON true
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = f.customer_id
   WHERE cb.list_data_id = v_company
     AND (v_scope IS NULL OR cb.customer_id = ANY(v_scope))
     AND (v_branches IS NULL OR cb.customer_id = ANY(v_branches));

  CASE p_tool
    WHEN 'requests_by_status' THEN
      v_columns := '["status","lines","orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('status', x.status, 'lines', x.lines, 'orders', x.orders) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Unknown') AS status, count(*) AS lines, count(DISTINCT qi.quotation_id) AS orders
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'requests_over_time' THEN
      v_columns := '["period","orders","lines"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('period', to_char(x.period, 'YYYY-MM-DD'), 'orders', x.orders, 'lines', x.lines) ORDER BY x.period), '[]') INTO v_rows
        FROM (SELECT date_trunc(v_bucket, s.created_at) AS period, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 ORDER BY 1 LIMIT v_limit) x;

    WHEN 'confirmation_time_by_branch' THEN
      v_columns := '["branch","orders","avg_hours","median_hours"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'orders', x.orders, 'avg_hours', x.avg_hours, 'median_hours', x.median_hours) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS orders,
                     round((avg(EXTRACT(EPOCH FROM (co.created_at - s.created_at))) / 3600)::numeric, 1) AS avg_hours,
                     round((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (co.created_at - s.created_at))) / 3600)::numeric, 1) AS median_hours
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'vendor_response_times' THEN
      v_columns := '["vendor","requests","offers","avg_response_hours","avg_cost"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'requests', x.requests, 'offers', x.offers, 'avg_response_hours', x.avg_response_hours, 'avg_cost', x.avg_cost) ORDER BY x.offers DESC), '[]') INTO v_rows
        FROM (SELECT v.vendor_name AS vendor, count(DISTINCT qv.quotation_vendor_id) AS requests,
                     count(qvi.cost_id) FILTER (WHERE COALESCE(qvi.cost, 0) > 0) AS offers,
                     round((avg(EXTRACT(EPOCH FROM (qvi.updated_at - qv.created_at))) FILTER (WHERE COALESCE(qvi.cost, 0) > 0) / 3600)::numeric, 1) AS avg_response_hours,
                     round(avg(qvi.cost) FILTER (WHERE COALESCE(qvi.cost, 0) > 0)::numeric, 2) AS avg_cost
                FROM ai_scope s
                JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_id = s.quotation_id
                JOIN qvm_new_apps.vendors v ON v.vendor_id = qv.vendor_id
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.quotation_vendor_id = qv.quotation_vendor_id
               WHERE qv.created_at >= r.date_from AND qv.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'purchase_totals_by_vendor' THEN
      v_columns := '["vendor","purchase_orders","items","total_cost"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'purchase_orders', x.purchase_orders, 'items', x.items, 'total_cost', x.total_cost) ORDER BY x.total_cost DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(DISTINCT po.purchase_order_id) AS purchase_orders, count(pi.purchase_item_id) AS items,
                     round(sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1))::numeric, 2) AS total_cost
                FROM ai_scope s
                JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id)
               WHERE po.created_at >= r.date_from AND po.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'order_value_by_branch' THEN
      v_columns := '["branch","orders","lines","value_before_vat"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'orders', x.orders, 'lines', x.lines, 'value_before_vat', x.value_before_vat) ORDER BY x.value_before_vat DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(DISTINCT co.confirmed_order_id) AS orders, count(ci.confirmed_item_id) AS lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS value_before_vat
                FROM ai_scope s
                JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'top_parts' THEN
      v_columns := '["part","part_number","requests","quantity"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('part', x.part, 'part_number', x.part_number, 'requests', x.requests, 'quantity', x.quantity) ORDER BY x.requests DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(NULLIF(btrim(qi.part_description), ''), '—') AS part, COALESCE(NULLIF(btrim(qi.part_number), ''), '—') AS part_number,
                     count(*) AS requests, sum(COALESCE(qi.quantity, 1)) AS quantity
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1, 2 ORDER BY 3 DESC LIMIT v_limit) x;

    WHEN 'returns_summary' THEN
      v_columns := '["return_type","lines","quantity"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('return_type', x.return_type, 'lines', x.lines, 'quantity', x.quantity) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Return') AS return_type, count(*) AS lines, sum(COALESCE(ci.approved_qty, 1)) AS quantity
                FROM ai_scope s
                JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ci.return_type
               WHERE ci.return_type IS NOT NULL
                 AND ci.updated_at >= r.date_from AND ci.updated_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'account_manager_workload' THEN
      v_columns := '["account_manager","orders","open_orders","confirmed_orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('account_manager', x.account_manager, 'orders', x.orders, 'open_orders', x.open_orders, 'confirmed_orders', x.confirmed_orders) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ud.user_name, 'Unassigned') AS account_manager, count(*) AS orders,
                     count(*) FILTER (WHERE co.confirmed_order_id IS NULL) AS open_orders,
                     count(*) FILTER (WHERE co.confirmed_order_id IS NOT NULL) AS confirmed_orders
                FROM ai_scope s
                JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = q.account_manager
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'delivery_pipeline' THEN
      v_columns := '["branch","processing","out_for_delivery","dn_sign_pending","delivered","invoiced_or_settled"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'processing', x.processing, 'out_for_delivery', x.out_for_delivery, 'dn_sign_pending', x.dn_sign_pending, 'delivered', x.delivered, 'invoiced_or_settled', x.invoiced_or_settled) ORDER BY x.processing + x.out_for_delivery DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch,
                     count(*) FILTER (WHERE ci.item_status = 21) AS processing, count(*) FILTER (WHERE ci.item_status = 22) AS out_for_delivery,
                     count(*) FILTER (WHERE ci.item_status = 213) AS dn_sign_pending, count(*) FILTER (WHERE ci.item_status = 23) AS delivered,
                     count(*) FILTER (WHERE ci.item_status IN (25, 26, 31)) AS invoiced_or_settled
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'delivery_lead_time' THEN
      v_columns := '["branch","deliveries","avg_hours","median_hours"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'deliveries', x.deliveries, 'avg_hours', x.avg_hours, 'median_hours', x.median_hours) ORDER BY x.deliveries DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS deliveries,
                     round((avg(EXTRACT(EPOCH FROM (d.delivery_date::timestamptz - co.created_at))) / 3600)::numeric, 1) AS avg_hours,
                     round((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (d.delivery_date::timestamptz - co.created_at))) / 3600)::numeric, 1) AS median_hours
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.deliveries d ON d.confirmed_order_id = co.confirmed_order_id
               WHERE d.delivery_date IS NOT NULL AND d.delivery_date::timestamptz >= r.date_from AND d.delivery_date::timestamptz < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'orders_by_delivery_type' THEN
      v_columns := '["delivery_type","orders","lines","confirmed_orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('delivery_type', x.delivery_type, 'orders', x.orders, 'lines', x.lines, 'confirmed_orders', x.confirmed_orders) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Unknown') AS delivery_type, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines,
                     count(DISTINCT co.confirmed_order_id) AS confirmed_orders
                FROM ai_scope s JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = q.delivery_type
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'orders_by_order_type' THEN
      v_columns := '["order_type","orders","lines","confirmed_orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('order_type', x.order_type, 'orders', x.orders, 'lines', x.lines, 'confirmed_orders', x.confirmed_orders) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Unknown') AS order_type, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines,
                     count(DISTINCT co.confirmed_order_id) AS confirmed_orders
                FROM ai_scope s JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = q.order_type
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'purchase_cycle_time' THEN
      v_columns := '["vendor","purchase_orders","avg_hours_to_po","median_hours_to_po"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'purchase_orders', x.purchase_orders, 'avg_hours_to_po', x.avg_hours_to_po, 'median_hours_to_po', x.median_hours_to_po) ORDER BY x.purchase_orders DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS purchase_orders,
                     round((avg(EXTRACT(EPOCH FROM (po.created_at - co.created_at))) / 3600)::numeric, 1) AS avg_hours_to_po,
                     round((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (po.created_at - co.created_at))) / 3600)::numeric, 1) AS median_hours_to_po
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = po.vendor_id
               WHERE po.created_at >= r.date_from AND po.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'supplier_invoice_lag' THEN
      v_columns := '["vendor","purchase_orders","invoices_uploaded","missing_invoices","avg_days_to_invoice"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'purchase_orders', x.purchase_orders, 'invoices_uploaded', x.invoices_uploaded, 'missing_invoices', x.missing_invoices, 'avg_days_to_invoice', x.avg_days_to_invoice) ORDER BY x.missing_invoices DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS purchase_orders,
                     count(po.uploaded_at) AS invoices_uploaded, count(*) - count(po.uploaded_at) AS missing_invoices,
                     round((avg(EXTRACT(EPOCH FROM (po.uploaded_at - po.created_at))) / 86400)::numeric, 1) AS avg_days_to_invoice
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = po.vendor_id
               WHERE po.created_at >= r.date_from AND po.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'invoicing_status' THEN
      v_columns := '["branch","delivered_lines","invoiced_lines","settled_lines","awaiting_invoice"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'delivered_lines', x.delivered_lines, 'invoiced_lines', x.invoiced_lines, 'settled_lines', x.settled_lines, 'awaiting_invoice', x.awaiting_invoice) ORDER BY x.awaiting_invoice DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch,
                     count(*) FILTER (WHERE ci.item_status IN (23, 25, 26, 31)) AS delivered_lines,
                     count(*) FILTER (WHERE EXISTS (SELECT 1 FROM qvm_new_apps.invoice_items ii WHERE ii.confirmed_item_id = ci.confirmed_item_id)) AS invoiced_lines,
                     count(*) FILTER (WHERE ci.item_status = 31) AS settled_lines,
                     count(*) FILTER (WHERE ci.item_status IN (23, 25) AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.invoice_items ii WHERE ii.confirmed_item_id = ci.confirmed_item_id)) AS awaiting_invoice
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'invoice_aging' THEN
      v_columns := '["branch","invoices","paid","open","overdue","avg_days_to_pay"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'invoices', x.invoices, 'paid', x.paid, 'open', x.open, 'overdue', x.overdue, 'avg_days_to_pay', x.avg_days_to_pay) ORDER BY x.overdue DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS invoices, count(i.paid_at) AS paid, count(*) - count(i.paid_at) AS open,
                     count(*) FILTER (WHERE i.paid_at IS NULL AND i.due_date IS NOT NULL AND i.due_date::timestamptz < now()) AS overdue,
                     round((avg(EXTRACT(EPOCH FROM (i.paid_at - i.created_at))) / 86400)::numeric, 1) AS avg_days_to_pay
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.invoices i ON i.confirmed_order_id = co.confirmed_order_id
               WHERE i.created_at >= r.date_from AND i.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'sales_vs_cost_margin' THEN
      v_columns := '["branch","lines","revenue_before_vat","purchase_cost","margin","margin_pct"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'lines', x.lines, 'revenue_before_vat', x.revenue_before_vat, 'purchase_cost', x.purchase_cost, 'margin', x.margin, 'margin_pct', x.margin_pct) ORDER BY x.revenue_before_vat DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS revenue_before_vat,
                     round(sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS purchase_cost,
                     round((sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)) - sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)))::numeric, 2) AS margin,
                     round((100 * (1 - sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)) / NULLIF(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)), 0)))::numeric, 1) AS margin_pct
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
                LEFT JOIN LATERAL (SELECT p.final_purchase_price, p.cost_id FROM qvm_new_apps.purchase_items p WHERE p.confirmed_item_id = ci.confirmed_item_id ORDER BY p.created_at DESC LIMIT 1) pi ON true
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = COALESCE(pi.cost_id, qi.cost_id)
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'margin_over_time' THEN
      v_columns := '["period","lines","revenue_before_vat","purchase_cost","margin_pct"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('period', x.period, 'lines', x.lines, 'revenue_before_vat', x.revenue_before_vat, 'purchase_cost', x.purchase_cost, 'margin_pct', x.margin_pct) ORDER BY x.period), '[]') INTO v_rows
        FROM (SELECT to_char(date_trunc(v_bucket, co.created_at), 'YYYY-MM-DD') AS period, count(*) AS lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS revenue_before_vat,
                     round(sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS purchase_cost,
                     round((100 * (1 - sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)) / NULLIF(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1)), 0)))::numeric, 1) AS margin_pct
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
                LEFT JOIN LATERAL (SELECT p.final_purchase_price, p.cost_id FROM qvm_new_apps.purchase_items p WHERE p.confirmed_item_id = ci.confirmed_item_id ORDER BY p.created_at DESC LIMIT 1) pi ON true
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = COALESCE(pi.cost_id, qi.cost_id)
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'cancellations_summary' THEN
      v_columns := '["reason","lines","orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('reason', x.reason, 'lines', x.lines, 'orders', x.orders) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Cancelled — no reason recorded') AS reason, count(*) AS lines, count(DISTINCT qi.quotation_id) AS orders
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ci.cancellation_reason
               WHERE (ci.cancellation_reason IS NOT NULL OR qi.item_status IN (18, 268))
                 AND s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'vendor_fill_rate' THEN
      v_columns := '["vendor","lines_sent","lines_priced","lines_won","fill_rate_pct","win_rate_pct"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'lines_sent', x.lines_sent, 'lines_priced', x.lines_priced, 'lines_won', x.lines_won, 'fill_rate_pct', x.fill_rate_pct, 'win_rate_pct', x.win_rate_pct) ORDER BY x.lines_sent DESC), '[]') INTO v_rows
        FROM (SELECT v.vendor_name AS vendor, count(*) AS lines_sent, count(*) FILTER (WHERE COALESCE(qvi.cost, 0) > 0) AS lines_priced,
                     count(*) FILTER (WHERE w.won) AS lines_won,
                     round(100.0 * count(*) FILTER (WHERE COALESCE(qvi.cost, 0) > 0) / NULLIF(count(*), 0), 1) AS fill_rate_pct,
                     round(100.0 * count(*) FILTER (WHERE w.won) / NULLIF(count(*) FILTER (WHERE COALESCE(qvi.cost, 0) > 0), 0), 1) AS win_rate_pct
                FROM ai_scope s JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_id = s.quotation_id
                JOIN qvm_new_apps.vendors v ON v.vendor_id = qv.vendor_id
                JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.quotation_vendor_id = qv.quotation_vendor_id
                LEFT JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items p WHERE p.cost_id = qvi.cost_id) AS won) w ON true
               WHERE qv.created_at >= r.date_from AND qv.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'vendor_price_rank' THEN
      v_columns := '["vendor","priced_lines","cheapest","pct_cheapest","avg_rank","avg_competitors"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'priced_lines', x.priced_lines, 'cheapest', x.cheapest, 'pct_cheapest', x.pct_cheapest, 'avg_rank', x.avg_rank, 'avg_competitors', x.avg_competitors) ORDER BY x.priced_lines DESC), '[]') INTO v_rows
        FROM (WITH offers AS (
                  SELECT qvi.vendor_id, qvi.cost, rank() OVER (PARTITION BY qvi.quotation_item_id ORDER BY qvi.cost) AS rnk,
                         count(*) OVER (PARTITION BY qvi.quotation_item_id) AS n
                    FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.quotation_item_id = qi.quotation_item_id
                   WHERE COALESCE(qvi.cost, 0) > 0 AND s.created_at >= r.date_from AND s.created_at < r.date_to)
                SELECT v.vendor_name AS vendor, count(*) AS priced_lines, count(*) FILTER (WHERE o.rnk = 1) AS cheapest,
                       round(100.0 * count(*) FILTER (WHERE o.rnk = 1) / NULLIF(count(*), 0), 1) AS pct_cheapest,
                       round(avg(o.rnk)::numeric, 2) AS avg_rank, round(avg(o.n)::numeric, 1) AS avg_competitors
                  FROM offers o JOIN qvm_new_apps.vendors v ON v.vendor_id = o.vendor_id
                 GROUP BY 1 LIMIT v_limit) x;

    WHEN 'extract_pn_turnaround' THEN
      v_columns := '["branch","orders","avg_hours","median_hours"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'orders', x.orders, 'avg_hours', x.avg_hours, 'median_hours', x.median_hours) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS orders,
                     round((avg(EXTRACT(EPOCH FROM (l.t - s.created_at))) / 3600)::numeric, 1) AS avg_hours,
                     round((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (l.t - s.created_at))) / 3600)::numeric, 1) AS median_hours
                FROM ai_scope s
                JOIN LATERAL (SELECT min(sl.created_at) AS t FROM qvm_new_apps.status_logs sl JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = sl.quotation_item_id
                               WHERE qi.quotation_id = s.quotation_id AND sl.item_status = 235) l ON l.t IS NOT NULL
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'tendering_turnaround' THEN
      v_columns := '["branch","orders_sent","orders_priced","avg_hours_to_first_offer"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'orders_sent', x.orders_sent, 'orders_priced', x.orders_priced, 'avg_hours_to_first_offer', x.avg_hours_to_first_offer) ORDER BY x.orders_sent DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS orders_sent, count(b.priced) AS orders_priced,
                     round((avg(EXTRACT(EPOCH FROM (b.priced - a.sent))) / 3600)::numeric, 1) AS avg_hours_to_first_offer
                FROM ai_scope s
                JOIN LATERAL (SELECT min(qv.created_at) AS sent FROM qvm_new_apps.quotation_vendors qv WHERE qv.quotation_id = s.quotation_id) a ON a.sent IS NOT NULL
                LEFT JOIN LATERAL (SELECT min(qvi.updated_at) AS priced FROM qvm_new_apps.quotation_vendors qv JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.quotation_vendor_id = qv.quotation_vendor_id
                                    WHERE qv.quotation_id = s.quotation_id AND COALESCE(qvi.cost, 0) > 0) b ON true
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'branch_overview' THEN
      v_columns := '["branch","orders","lines","confirmed_orders","delivered_lines","confirmed_value","avg_confirmation_hours"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'orders', x.orders, 'lines', x.lines, 'confirmed_orders', x.confirmed_orders, 'delivered_lines', x.delivered_lines, 'confirmed_value', x.confirmed_value, 'avg_confirmation_hours', x.avg_confirmation_hours) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines,
                     count(DISTINCT co.confirmed_order_id) AS confirmed_orders,
                     count(ci.confirmed_item_id) FILTER (WHERE ci.item_status IN (23, 25, 26, 31)) AS delivered_lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * ci.approved_qty) FILTER (WHERE ci.confirmed_item_id IS NOT NULL)::numeric, 2) AS confirmed_value,
                     round((avg(EXTRACT(EPOCH FROM (co.created_at - s.created_at))) / 3600)::numeric, 1) AS avg_confirmation_hours
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'monthly_summary' THEN
      v_columns := '["period","orders","lines","confirmed_orders","confirmed_value"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('period', x.period, 'orders', x.orders, 'lines', x.lines, 'confirmed_orders', x.confirmed_orders, 'confirmed_value', x.confirmed_value) ORDER BY x.period), '[]') INTO v_rows
        FROM (SELECT to_char(date_trunc('month', s.created_at), 'YYYY-MM') AS period, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines,
                     count(DISTINCT co.confirmed_order_id) AS confirmed_orders,
                     round(sum(COALESCE(qi.price_before_vat, 0) * ci.approved_qty) FILTER (WHERE ci.confirmed_item_id IS NOT NULL)::numeric, 2) AS confirmed_value
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'stock_coverage' THEN
      v_columns := '["vendor","requested_parts","parts_in_stock","coverage_pct"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'requested_parts', x.requested_parts, 'parts_in_stock', x.parts_in_stock, 'coverage_pct', x.coverage_pct) ORDER BY x.parts_in_stock DESC), '[]') INTO v_rows
        FROM (WITH req AS (
                  SELECT DISTINCT qvm_new_apps.normalize_part_number(qi.part_number) AS pn
                    FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                   WHERE s.created_at >= r.date_from AND s.created_at < r.date_to AND qvm_new_apps.normalize_part_number(qi.part_number) IS NOT NULL)
                SELECT v.vendor_name AS vendor, (SELECT count(*) FROM req) AS requested_parts, count(DISTINCT st.clean_part_number) AS parts_in_stock,
                       round(100.0 * count(DISTINCT st.clean_part_number) / GREATEST((SELECT count(*) FROM req), 1), 1) AS coverage_pct
                  FROM qvm_new_apps.inventory_stock st JOIN qvm_new_apps.vendors v ON v.vendor_id = st.vendor_id
                  JOIN req ON req.pn = st.clean_part_number
                 WHERE st.is_available
                 GROUP BY 1 LIMIT v_limit) x;

    ELSE
      RAISE EXCEPTION 'Unknown report tool %', p_tool;
  END CASE;

  INSERT INTO qvm_new_apps.ai_report_audit (user_id, company_id, action, client, tool_name, tool_params, row_count)
  VALUES (auth.uid(), v_company, 'tool', COALESCE(NULLIF(current_setting('qvm.ai_client', true), ''), 'web'), p_tool, p_params, jsonb_array_length(v_rows));

  RETURN jsonb_build_object(
    'tool', p_tool, 'params', p_params,
    'range', jsonb_build_object('label', r.label, 'from', r.date_from, 'to', r.date_to),
    'columns', v_columns, 'rows', v_rows, 'row_count', jsonb_array_length(v_rows), 'generated_at', now());
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_check_spec(p_spec jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE s jsonb; n integer := 0;
BEGIN
  IF p_spec IS NULL OR jsonb_typeof(p_spec) <> 'array' OR jsonb_array_length(p_spec) = 0 THEN
    RAISE EXCEPTION 'A report needs at least one section';
  END IF;
  IF jsonb_array_length(p_spec) > 8 THEN RAISE EXCEPTION 'A report has at most 8 sections'; END IF;
  FOR s IN SELECT * FROM jsonb_array_elements(p_spec) LOOP
    n := n + 1;
    IF COALESCE(s->>'tool', '') NOT IN ('requests_by_status', 'requests_over_time', 'confirmation_time_by_branch', 'vendor_response_times', 'purchase_totals_by_vendor', 'order_value_by_branch', 'top_parts', 'returns_summary', 'account_manager_workload', 'delivery_pipeline', 'delivery_lead_time', 'orders_by_delivery_type', 'orders_by_order_type', 'purchase_cycle_time', 'supplier_invoice_lag', 'invoicing_status', 'invoice_aging', 'sales_vs_cost_margin', 'margin_over_time', 'cancellations_summary', 'vendor_fill_rate', 'vendor_price_rank', 'extract_pn_turnaround', 'tendering_turnaround', 'branch_overview', 'monthly_summary', 'stock_coverage') THEN
      RAISE EXCEPTION 'Section % names an unknown tool %', n, s->>'tool';
    END IF;
    IF COALESCE(s->>'visual', '') NOT IN ('kpi', 'bar', 'line', 'table') THEN
      RAISE EXCEPTION 'Section % names an unknown visual %', n, s->>'visual';
    END IF;
    IF s ? 'params' AND jsonb_typeof(s->'params') <> 'object' THEN RAISE EXCEPTION 'Section % has malformed params', n; END IF;
  END LOOP;
END $function$;
