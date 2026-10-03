-- The AI report tools read an empty value as «none».
--
-- The model's tool schemas allow few nullable parameters, so a parameter that does not apply
-- arrives as an empty string or an empty list rather than null: no custom dates, every branch,
-- the usual row count. The tools now read those the same way they read null.

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_range(p_params jsonb, OUT date_from timestamptz, OUT date_to timestamptz, OUT label text)
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE v_range text := COALESCE(p_params->>'range', 'last_30_days');
BEGIN
  date_to := now();
  CASE v_range
    WHEN 'last_7_days'   THEN date_from := now() - interval '7 days';
    WHEN 'last_30_days'  THEN date_from := now() - interval '30 days';
    WHEN 'last_90_days'  THEN date_from := now() - interval '90 days';
    WHEN 'last_12_months' THEN date_from := now() - interval '12 months';
    WHEN 'this_month'    THEN date_from := date_trunc('month', now());
    WHEN 'last_month'    THEN date_from := date_trunc('month', now()) - interval '1 month'; date_to := date_trunc('month', now());
    WHEN 'this_year'     THEN date_from := date_trunc('year', now());
    WHEN 'custom'        THEN date_from := COALESCE(NULLIF(p_params->>'date_from', '')::timestamptz, now() - interval '30 days');
                              date_to := COALESCE(NULLIF(p_params->>'date_to', '')::timestamptz, now());
    ELSE RAISE EXCEPTION 'Unknown range %', v_range;
  END CASE;
  label := v_range;
END $function$;

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
