-- AI reports from a prompt, for the company's admins.
--
-- The feature as it runs on QVM/test, brought to dev and fitted to dev's design:
--
--   * Who: a Company Admin composes and reads reports over their own company; the Qparts Admin
--     over every company (the scope is then open and a report they save belongs to no one
--     company). Nobody else — the reports are the company's management view, not every internal
--     user's. ai_caller_company() is the one gate; every function asks it.
--   * What: thirty report tools, each a query written here, scoped to the caller's company (through
--     the lines' branches, as every dashboard scopes) and branch scope, read-only, capped, audited.
--     Two read dev's own records instead of proxies — returns from the return log, cancellations
--     from the cancellation records — and three exist only here: approval rounds, shipments, and
--     purchase receipts, whose tables test does not have.
--   * How: a Company Admin describes the report on the Management Overview; Claude picks tools and
--     composes a recipe; the recipe is what is saved and re-run. The same tools serve the MCP
--     server, which a personal access token (made on the profile) opens to the same two roles.
--
-- Tables: ai_reports (the recipes and their last data), ai_report_audit (every generation and tool
-- call), api_tokens (hashed personal tokens). The app calls the functions without a schema, so
-- each has a public wrapper.

-- ───────────────────────────── tables ─────────────────────────────

CREATE TABLE IF NOT EXISTS qvm_new_apps.ai_reports (
  report_id    bigserial PRIMARY KEY,
  -- The company whose data the report reads; NULL for a report the Qparts Admin composed over every company.
  company_id   integer,
  created_by   uuid NOT NULL DEFAULT auth.uid(),
  title        text NOT NULL,
  prompt       text NOT NULL,
  -- The recipe: [{tool, params, visual, title, insight}], validated by save_ai_report.
  spec         jsonb NOT NULL,
  -- The data the recipe produced when it last ran, one entry per section.
  last_result  jsonb,
  last_run_at  timestamptz,
  -- When the insights were written; the data may have moved since.
  insights_at  timestamptz,
  model        text,
  source       text NOT NULL DEFAULT 'web' CHECK (source IN ('web', 'mcp')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz
);
COMMENT ON TABLE qvm_new_apps.ai_reports IS 'A report composed from a prompt: the recipe of tool calls and visuals, and the data it last produced.';
CREATE INDEX IF NOT EXISTS ix_ai_reports_company ON qvm_new_apps.ai_reports (company_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS qvm_new_apps.ai_report_audit (
  audit_id      bigserial PRIMARY KEY,
  report_id     bigint REFERENCES qvm_new_apps.ai_reports(report_id) ON DELETE SET NULL,
  user_id       uuid NOT NULL,
  company_id    integer,
  action        text NOT NULL CHECK (action IN ('create', 'refine', 'refresh', 'tool', 'insights')),
  client        text NOT NULL DEFAULT 'web' CHECK (client IN ('web', 'mcp')),
  prompt        text,
  tool_name     text,
  tool_params   jsonb,
  row_count     integer,
  model         text,
  input_tokens  integer,
  output_tokens integer,
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE qvm_new_apps.ai_report_audit IS 'Every generation, refinement, refresh and tool call behind the AI reports: who, what, how many rows, how many tokens.';
CREATE INDEX IF NOT EXISTS ix_ai_report_audit_user_time ON qvm_new_apps.ai_report_audit (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS qvm_new_apps.api_tokens (
  token_id      bigserial PRIMARY KEY,
  user_id       uuid NOT NULL,
  name          text NOT NULL,
  -- Only the hash is kept; the token itself is shown once, when it is made.
  token_hash    text NOT NULL UNIQUE,
  token_prefix  text NOT NULL,
  expires_at    timestamptz,
  last_used_at  timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE qvm_new_apps.api_tokens IS 'Personal access tokens for the MCP server; the token is hashed, shown once, and tied to one user.';
CREATE INDEX IF NOT EXISTS ix_api_tokens_user ON qvm_new_apps.api_tokens (user_id);

ALTER TABLE qvm_new_apps.ai_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.ai_report_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.api_tokens ENABLE ROW LEVEL SECURITY;

-- ───────────────────────────── who is asking ─────────────────────────────

-- The company whose data the caller reads: a Company Admin reads their own company; the Qparts
-- Admin reads every company (NULL). Anyone else is refused — the reports are the company's
-- management view, not every internal user's. The company comes from the account, never from a
-- parameter.
CREATE OR REPLACE FUNCTION qvm_new_apps.ai_caller_company()
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer; v_role integer; v_type integer;
BEGIN
  SELECT ud.user_company, ud.user_role, ud.user_type INTO v_company, v_role, v_type
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = auth.uid() AND ud.deleted_at IS NULL;
  IF v_type = 185 AND v_role = 172 THEN RETURN NULL; END IF;            -- the Qparts Admin: everything
  IF v_role = qvm_new_apps.company_admin_role_id() THEN
    IF v_company IS NULL THEN RAISE EXCEPTION 'Your account has no company'; END IF;
    RETURN v_company;
  END IF;
  RAISE EXCEPTION 'AI reports are for company admins and the Qparts Admin';
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_caller_company() FROM PUBLIC, anon, authenticated;

-- A date range as the tools take it: a relative key, or an explicit from/to.
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

-- ───────────────────────────── the tools ─────────────────────────────

-- Runs one report tool for the caller. p_params: {range, date_from, date_to, branch_ids, bucket,
-- limit}. Returns {tool, params, columns, rows, row_count, generated_at}. Rows are capped.
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

  -- Every tool reads from the same scope: the caller's company's orders (every company for the
  -- Qparts Admin), within the caller's branch scope and the branches asked for, in the range.
  IF to_regclass('pg_temp.ai_scope') IS NOT NULL THEN DROP TABLE ai_scope; END IF;
  CREATE TEMP TABLE ai_scope (quotation_id integer, branch_id integer, branch_name text, created_at timestamptz) ON COMMIT DROP;
  INSERT INTO ai_scope
  SELECT q.quotation_id, cb.customer_id, cb.branch_name, q.created_at
    FROM qvm_new_apps.quotations q
    JOIN LATERAL (SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id LIMIT 1) f ON true
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = f.customer_id
   WHERE (v_company IS NULL OR cb.list_data_id = v_company)
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
      -- The return log: one row per approved return of a line, with its type and quantity.
      v_columns := '["return_type","lines","quantity","full_returns"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('return_type', x.return_type, 'lines', x.lines, 'quantity', x.quantity, 'full_returns', x.full_returns) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Return') AS return_type, count(*) AS lines, sum(COALESCE(rl.returned_qty, 0)) AS quantity,
                     count(*) FILTER (WHERE rl.is_full_return) AS full_returns
                FROM ai_scope s
                JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.confirmed_item_return_log rl ON rl.confirmed_item_id = ci.confirmed_item_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = rl.return_type
               WHERE COALESCE(rl.approved_at, ci.updated_at) >= r.date_from AND COALESCE(rl.approved_at, ci.updated_at) < r.date_to
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
      -- The cancellation records: who cancelled (Qparts or the vendor), why, how much.
      v_columns := '["reason","source","lines","quantity","orders"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('reason', x.reason, 'source', x.source, 'lines', x.lines, 'quantity', x.quantity, 'orders', x.orders) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'No reason recorded') AS reason, COALESCE(c.source, 'unknown') AS source,
                     count(*) AS lines, sum(COALESCE(c.qty, 0)) AS quantity, count(DISTINCT qi.quotation_id) AS orders
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                JOIN qvm_new_apps.quotation_item_cancellations c ON c.quotation_item_id = qi.quotation_item_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = c.reason_id
               WHERE c.created_at >= r.date_from AND c.created_at < r.date_to
               GROUP BY 1, 2 LIMIT v_limit) x;

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

    WHEN 'approvals_summary' THEN
      -- Quotation approval rounds per audience (the workshop, the end customer): how many were
      -- sent, how they were answered, and how long the answer took.
      v_columns := '["audience","rounds","approved","rejected","revision_requested","pending","avg_hours_to_decide"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('audience', x.audience, 'rounds', x.rounds, 'approved', x.approved, 'rejected', x.rejected, 'revision_requested', x.revision_requested, 'pending', x.pending, 'avg_hours_to_decide', x.avg_hours_to_decide) ORDER BY x.rounds DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ar.audience, 'unknown') AS audience, count(*) AS rounds,
                     count(*) FILTER (WHERE ar.status = 'approved') AS approved, count(*) FILTER (WHERE ar.status = 'rejected') AS rejected,
                     count(*) FILTER (WHERE ar.status = 'revision_requested') AS revision_requested, count(*) FILTER (WHERE ar.status = 'pending') AS pending,
                     round((avg(EXTRACT(EPOCH FROM (ar.decided_at - ar.sent_at))) FILTER (WHERE ar.decided_at IS NOT NULL AND ar.sent_at IS NOT NULL) / 3600)::numeric, 1) AS avg_hours_to_decide
                FROM ai_scope s JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.quotation_id = s.quotation_id
               WHERE COALESCE(ar.sent_at, s.created_at) >= r.date_from AND COALESCE(ar.sent_at, s.created_at) < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'shipments_summary' THEN
      -- Shipments by status, with the hours from dispatch to delivery and what they cost and earned.
      v_columns := '["status","shipments","avg_hours_to_deliver","total_cost","total_price"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('status', x.status, 'shipments', x.shipments, 'avg_hours_to_deliver', x.avg_hours_to_deliver, 'total_cost', x.total_cost, 'total_price', x.total_price) ORDER BY x.shipments DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Unknown') AS status, count(*) AS shipments,
                     round((avg(EXTRACT(EPOCH FROM (sh.delivered_at - COALESCE(sh.dispatched_at, sh.created_at)))) FILTER (WHERE sh.delivered_at IS NOT NULL) / 3600)::numeric, 1) AS avg_hours_to_deliver,
                     round(sum(COALESCE(sh.cost, 0))::numeric, 2) AS total_cost, round(sum(COALESCE(sh.price, 0))::numeric, 2) AS total_price
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.shipments sh ON sh.confirmed_order_id = co.confirmed_order_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = sh.status_id
               WHERE sh.created_at >= r.date_from AND sh.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'receipt_status_by_vendor' THEN
      -- Purchase lines per vendor by how they arrived: received in full, short, not yet, and what went back.
      v_columns := '["vendor","lines","received","lower_qty","not_received","returned_qty"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'lines', x.lines, 'received', x.received, 'lower_qty', x.lower_qty, 'not_received', x.not_received, 'returned_qty', x.returned_qty) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS lines,
                     count(*) FILTER (WHERE pi.receipt_status = 'received') AS received,
                     count(*) FILTER (WHERE pi.receipt_status = 'lower_qty') AS lower_qty,
                     count(*) FILTER (WHERE COALESCE(pi.receipt_status, 'not_received') = 'not_received') AS not_received,
                     sum(COALESCE(pi.returned_qty, 0)) AS returned_qty
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = po.vendor_id
               WHERE po.created_at >= r.date_from AND po.created_at < r.date_to
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

-- A recipe must be a short list of sections, each naming a known tool and a known visual.
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
    IF COALESCE(s->>'tool', '') NOT IN ('requests_by_status', 'requests_over_time', 'confirmation_time_by_branch', 'vendor_response_times', 'purchase_totals_by_vendor', 'order_value_by_branch', 'top_parts', 'returns_summary', 'account_manager_workload', 'delivery_pipeline', 'delivery_lead_time', 'orders_by_delivery_type', 'orders_by_order_type', 'purchase_cycle_time', 'supplier_invoice_lag', 'invoicing_status', 'invoice_aging', 'sales_vs_cost_margin', 'margin_over_time', 'cancellations_summary', 'vendor_fill_rate', 'vendor_price_rank', 'extract_pn_turnaround', 'tendering_turnaround', 'branch_overview', 'monthly_summary', 'stock_coverage', 'approvals_summary', 'shipments_summary', 'receipt_status_by_vendor') THEN
      RAISE EXCEPTION 'Section % names an unknown tool %', n, s->>'tool';
    END IF;
    IF COALESCE(s->>'visual', '') NOT IN ('kpi', 'bar', 'line', 'table') THEN
      RAISE EXCEPTION 'Section % names an unknown visual %', n, s->>'visual';
    END IF;
    IF s ? 'params' AND jsonb_typeof(s->'params') <> 'object' THEN RAISE EXCEPTION 'Section % has malformed params', n; END IF;
  END LOOP;
END $function$;

-- ───────────────────────────── the reports ─────────────────────────────

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_json(p_report_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'report_id', r.report_id, 'title', r.title, 'prompt', r.prompt, 'spec', r.spec,
           'last_result', r.last_result, 'last_run_at', r.last_run_at, 'insights_at', r.insights_at,
           'model', r.model, 'source', r.source, 'company_id', r.company_id, 'created_at', r.created_at, 'updated_at', r.updated_at,
           'created_by', r.created_by, 'created_by_name', ud.user_name)
    FROM qvm_new_apps.ai_reports r
    LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = r.created_by
   WHERE r.report_id = p_report_id AND r.deleted_at IS NULL;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_report_json(bigint) FROM PUBLIC, anon, authenticated;

-- Runs every section of a recipe and returns the results, one per section, in order.
CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_execute(p_spec jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE s jsonb; out jsonb := '[]'::jsonb;
BEGIN
  FOR s IN SELECT * FROM jsonb_array_elements(p_spec) LOOP
    out := out || jsonb_build_array(qvm_new_apps.ai_report_tool(s->>'tool', COALESCE(s->'params', '{}'::jsonb)));
  END LOOP;
  RETURN out;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_report_execute(jsonb) FROM PUBLIC, anon, authenticated;

-- Saves a recipe (new, or over an existing report the caller may read) and runs it.
CREATE OR REPLACE FUNCTION qvm_new_apps.save_ai_report(p_report_id bigint, p_title text, p_prompt text, p_spec jsonb, p_model text DEFAULT NULL, p_source text DEFAULT 'web')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company(); v_id bigint := p_report_id; v_result jsonb;
BEGIN
  IF COALESCE(btrim(p_title), '') = '' THEN RAISE EXCEPTION 'A report needs a title'; END IF;
  PERFORM qvm_new_apps.ai_report_check_spec(p_spec);
  v_result := qvm_new_apps.ai_report_execute(p_spec);
  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.ai_reports (company_id, created_by, title, prompt, spec, last_result, last_run_at, insights_at, model, source, updated_by)
    VALUES (v_company, auth.uid(), btrim(p_title), COALESCE(p_prompt, ''), p_spec, v_result, now(), now(), p_model,
            CASE WHEN p_source IN ('web', 'mcp') THEN p_source ELSE 'web' END, auth.uid())
    RETURNING report_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.ai_reports
       SET title = btrim(p_title), prompt = COALESCE(p_prompt, prompt), spec = p_spec, last_result = v_result, last_run_at = now(),
           insights_at = now(), model = COALESCE(p_model, model), updated_by = auth.uid(), updated_at = now()
     WHERE report_id = v_id AND (v_company IS NULL OR company_id = v_company) AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown report'; END IF;
  END IF;
  RETURN qvm_new_apps.ai_report_json(v_id);
END $function$;

-- Re-runs a saved recipe against live data. No model is involved; the insights keep their date.
CREATE OR REPLACE FUNCTION qvm_new_apps.run_ai_report(p_report_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company(); v_spec jsonb;
BEGIN
  SELECT spec INTO v_spec FROM qvm_new_apps.ai_reports WHERE report_id = p_report_id AND (v_company IS NULL OR company_id = v_company) AND deleted_at IS NULL;
  IF v_spec IS NULL THEN RAISE EXCEPTION 'Unknown report'; END IF;
  UPDATE qvm_new_apps.ai_reports SET last_result = qvm_new_apps.ai_report_execute(v_spec), last_run_at = now(), updated_at = now()
   WHERE report_id = p_report_id;
  INSERT INTO qvm_new_apps.ai_report_audit (report_id, user_id, company_id, action, client)
  VALUES (p_report_id, auth.uid(), v_company, 'refresh', COALESCE(NULLIF(current_setting('qvm.ai_client', true), ''), 'web'));
  RETURN qvm_new_apps.ai_report_json(p_report_id);
END $function$;

-- The written insights rewritten over fresh numbers (the model wrote them; this only stores them).
CREATE OR REPLACE FUNCTION qvm_new_apps.update_ai_report_insights(p_report_id bigint, p_insights jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company(); v_spec jsonb; i integer := 0; s jsonb; v_new jsonb := '[]'::jsonb;
BEGIN
  SELECT spec INTO v_spec FROM qvm_new_apps.ai_reports WHERE report_id = p_report_id AND (v_company IS NULL OR company_id = v_company) AND deleted_at IS NULL;
  IF v_spec IS NULL THEN RAISE EXCEPTION 'Unknown report'; END IF;
  IF jsonb_typeof(p_insights) <> 'array' THEN RAISE EXCEPTION 'Insights must be a list, one per section'; END IF;
  FOR s IN SELECT * FROM jsonb_array_elements(v_spec) LOOP
    v_new := v_new || jsonb_build_array(s || jsonb_build_object('insight', COALESCE(p_insights->>i, s->>'insight')));
    i := i + 1;
  END LOOP;
  UPDATE qvm_new_apps.ai_reports SET spec = v_new, insights_at = now(), updated_by = auth.uid(), updated_at = now() WHERE report_id = p_report_id;
  RETURN qvm_new_apps.ai_report_json(p_report_id);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_ai_reports()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(qvm_new_apps.ai_report_json(r.report_id) ORDER BY r.updated_at DESC)
                     FROM qvm_new_apps.ai_reports r WHERE (v_company IS NULL OR r.company_id = v_company) AND r.deleted_at IS NULL), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_ai_report(p_report_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.ai_reports WHERE report_id = p_report_id AND (v_company IS NULL OR company_id = v_company) AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Unknown report';
  END IF;
  RETURN qvm_new_apps.ai_report_json(p_report_id);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_ai_report(p_report_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company();
BEGIN
  UPDATE qvm_new_apps.ai_reports SET deleted_at = now(), updated_by = auth.uid()
   WHERE report_id = p_report_id AND (v_company IS NULL OR company_id = v_company) AND deleted_at IS NULL
     AND (created_by = auth.uid() OR qvm_new_apps.is_qparts_admin());
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown report, or not yours to remove'; END IF;
  RETURN jsonb_build_object('status', 'success');
END $function$;

-- The generation's own audit row, written by the edge function once the model has answered.
-- Also the rate limit: a few generations a minute, a bounded number a day, per user.
CREATE OR REPLACE FUNCTION qvm_new_apps.log_ai_report_generation(p_report_id bigint, p_action text, p_prompt text, p_model text, p_input_tokens integer, p_output_tokens integer, p_client text DEFAULT 'web')
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company();
BEGIN
  IF p_action NOT IN ('create', 'refine', 'insights') THEN RAISE EXCEPTION 'Unknown action'; END IF;
  INSERT INTO qvm_new_apps.ai_report_audit (report_id, user_id, company_id, action, client, prompt, model, input_tokens, output_tokens)
  VALUES (p_report_id, auth.uid(), v_company, p_action, CASE WHEN p_client IN ('web', 'mcp') THEN p_client ELSE 'web' END, left(p_prompt, 4000), p_model, p_input_tokens, p_output_tokens);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_report_rate_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company(); v_minute integer; v_day integer;
BEGIN
  SELECT count(*) FILTER (WHERE created_at > now() - interval '1 minute'), count(*) INTO v_minute, v_day
    FROM qvm_new_apps.ai_report_audit
   WHERE user_id = auth.uid() AND action IN ('create', 'refine', 'insights') AND created_at > now() - interval '1 day';
  RETURN jsonb_build_object('allowed', v_minute < 5 AND v_day < 100, 'last_minute', v_minute, 'last_day', v_day, 'company_id', v_company);
END $function$;

-- ───────────────────────────── personal access tokens (MCP) ─────────────────────────────

-- Makes a token for the caller and returns it once; only its hash is kept.
CREATE OR REPLACE FUNCTION qvm_new_apps.create_api_token(p_name text, p_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_token text; v_id bigint; v_expires timestamptz;
BEGIN
  PERFORM qvm_new_apps.ai_caller_company();   -- company admins and the Qparts Admin only
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'A token needs a name'; END IF;
  IF (SELECT count(*) FROM qvm_new_apps.api_tokens WHERE user_id = auth.uid() AND revoked_at IS NULL) >= 10 THEN
    RAISE EXCEPTION 'You already have 10 active tokens; revoke one first';
  END IF;
  v_token := 'qvm_' || encode(extensions.gen_random_bytes(24), 'hex');
  v_expires := CASE WHEN p_days IS NULL OR p_days <= 0 THEN NULL ELSE now() + make_interval(days => LEAST(p_days, 365)) END;
  INSERT INTO qvm_new_apps.api_tokens (user_id, name, token_hash, token_prefix, expires_at)
  VALUES (auth.uid(), btrim(p_name), encode(extensions.digest(v_token, 'sha256'), 'hex'), left(v_token, 12), v_expires)
  RETURNING token_id INTO v_id;
  RETURN jsonb_build_object('token_id', v_id, 'token', v_token, 'token_prefix', left(v_token, 12), 'expires_at', v_expires);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_api_tokens()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('token_id', t.token_id, 'name', t.name, 'token_prefix', t.token_prefix,
                                               'expires_at', t.expires_at, 'last_used_at', t.last_used_at, 'revoked_at', t.revoked_at, 'created_at', t.created_at)
                            ORDER BY t.created_at DESC), '[]'::jsonb)
    FROM qvm_new_apps.api_tokens t WHERE t.user_id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.revoke_api_token(p_token_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  UPDATE qvm_new_apps.api_tokens SET revoked_at = now() WHERE token_id = p_token_id AND user_id = auth.uid() AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown token'; END IF;
  RETURN jsonb_build_object('status', 'success');
END $function$;

-- The MCP server's lookup: the user behind a token, if it is live. Service role only.
CREATE OR REPLACE FUNCTION qvm_new_apps.resolve_api_token(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_user uuid; v_id bigint;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' AND current_user NOT IN ('postgres', 'service_role') THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  SELECT t.token_id, t.user_id INTO v_id, v_user
    FROM qvm_new_apps.api_tokens t
    JOIN qvm_new_apps.user_data ud ON ud.user_id = t.user_id AND ud.deleted_at IS NULL
     AND ((ud.user_type = 185 AND ud.user_role = 172) OR ud.user_role = qvm_new_apps.company_admin_role_id())
   WHERE t.token_hash = encode(extensions.digest(COALESCE(p_token, ''), 'sha256'), 'hex')
     AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now());
  IF v_user IS NULL THEN RETURN NULL; END IF;
  UPDATE qvm_new_apps.api_tokens SET last_used_at = now() WHERE token_id = v_id;
  RETURN v_user;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.resolve_api_token(text) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── the app calls these without a schema ─────────────────────────────

CREATE OR REPLACE FUNCTION public.ai_report_tool(p_tool text, p_params jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.ai_report_tool(p_tool, p_params) $function$;
CREATE OR REPLACE FUNCTION public.save_ai_report(p_report_id bigint, p_title text, p_prompt text, p_spec jsonb, p_model text DEFAULT NULL, p_source text DEFAULT 'web') RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.save_ai_report(p_report_id, p_title, p_prompt, p_spec, p_model, p_source) $function$;
CREATE OR REPLACE FUNCTION public.run_ai_report(p_report_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.run_ai_report(p_report_id) $function$;
CREATE OR REPLACE FUNCTION public.update_ai_report_insights(p_report_id bigint, p_insights jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.update_ai_report_insights(p_report_id, p_insights) $function$;
CREATE OR REPLACE FUNCTION public.list_ai_reports() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.list_ai_reports() $function$;
CREATE OR REPLACE FUNCTION public.get_ai_report(p_report_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.get_ai_report(p_report_id) $function$;
CREATE OR REPLACE FUNCTION public.delete_ai_report(p_report_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.delete_ai_report(p_report_id) $function$;
CREATE OR REPLACE FUNCTION public.log_ai_report_generation(p_report_id bigint, p_action text, p_prompt text, p_model text, p_input_tokens integer, p_output_tokens integer, p_client text DEFAULT 'web') RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.log_ai_report_generation(p_report_id, p_action, p_prompt, p_model, p_input_tokens, p_output_tokens, p_client) $function$;
CREATE OR REPLACE FUNCTION public.ai_report_rate_check() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.ai_report_rate_check() $function$;
CREATE OR REPLACE FUNCTION public.create_api_token(p_name text, p_days integer DEFAULT 90) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.create_api_token(p_name, p_days) $function$;
CREATE OR REPLACE FUNCTION public.list_api_tokens() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.list_api_tokens() $function$;
CREATE OR REPLACE FUNCTION public.revoke_api_token(p_token_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.revoke_api_token(p_token_id) $function$;
CREATE OR REPLACE FUNCTION public.resolve_api_token(p_token text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.resolve_api_token(p_token) $function$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'ai_report_tool(text, jsonb)', 'save_ai_report(bigint, text, text, jsonb, text, text)', 'run_ai_report(bigint)',
    'update_ai_report_insights(bigint, jsonb)', 'list_ai_reports()', 'get_ai_report(bigint)', 'delete_ai_report(bigint)',
    'log_ai_report_generation(bigint, text, text, text, integer, integer, text)', 'ai_report_rate_check()',
    'create_api_token(text, integer)', 'list_api_tokens()', 'revoke_api_token(bigint)'] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION qvm_new_apps.%s TO authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.resolve_api_token(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_api_token(text), qvm_new_apps.resolve_api_token(text) TO service_role;
