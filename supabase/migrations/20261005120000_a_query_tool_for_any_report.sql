-- A query tool for any report.
--
-- Forty named tools answer the questions somebody already thought of. The reports an admin may ask
-- for are not a finite list, so this adds the general case without letting the model write SQL:
--
--   * ai_build_fact materialises, per call, one row per quotation line in the caller's scope and
--     range, carrying every dimension and measure the data supports — branch, company, workshop,
--     city, region, vendor bought from, car brand, model, year, part category, service advisor,
--     account manager, delivery and order type, insurance company, end customer, statuses, receipt
--     status, dates and durations, prices, costs, offers, returns, cancellations.
--   * query_metrics groups that fact by any one or two dimensions and computes any measures, with
--     filters (vendors, statuses, brands, categories, types — matched by name, case-insensitive,
--     as a contained word so «Speed» finds «Speed Delivery» — a value band, a text search) and a sort.
--     The SQL is assembled from a fixed vocabulary of fragments; user text only ever travels as a
--     bound parameter. Rows are capped like every tool.
--   * query_lines lists the lines behind the same filters, newest first.
--   * vocabulary returns the dimension, measure and filter names, for an MCP client.
--
-- The named tools stay: they are faster to pick and read, and the model is told to prefer one
-- when it fits. Same gate, scope and audit for everything here.

-- ───────────────────────────── the fact ─────────────────────────────

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_build_fact(p_params jsonb, p_from timestamptz, p_to timestamptz, p_search text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_date_field text := CASE WHEN p_params->>'date_field' IN ('created', 'confirmed', 'delivered') THEN p_params->>'date_field' ELSE 'created' END;
  v_vendor_ids integer[] := CASE WHEN jsonb_typeof(p_params->'vendor_ids') = 'array' THEN NULLIF(ARRAY(SELECT x::integer FROM jsonb_array_elements_text(p_params->'vendor_ids') x), ARRAY[]::integer[]) END;
  v_statuses text[] := CASE WHEN jsonb_typeof(p_params->'statuses') = 'array' THEN NULLIF(ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'statuses') x WHERE btrim(x) <> ''), ARRAY[]::text[]) END;
  v_brands text[] := CASE WHEN jsonb_typeof(p_params->'car_brands') = 'array' THEN NULLIF(ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'car_brands') x WHERE btrim(x) <> ''), ARRAY[]::text[]) END;
  v_cats text[] := CASE WHEN jsonb_typeof(p_params->'part_categories') = 'array' THEN NULLIF(ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'part_categories') x WHERE btrim(x) <> ''), ARRAY[]::text[]) END;
  v_dtypes text[] := CASE WHEN jsonb_typeof(p_params->'delivery_types') = 'array' THEN NULLIF(ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'delivery_types') x WHERE btrim(x) <> ''), ARRAY[]::text[]) END;
  v_otypes text[] := CASE WHEN jsonb_typeof(p_params->'order_types') = 'array' THEN NULLIF(ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'order_types') x WHERE btrim(x) <> ''), ARRAY[]::text[]) END;
  v_min numeric := NULLIF(NULLIF(p_params->>'min_value', '')::numeric, 0);
  v_max numeric := NULLIF(NULLIF(p_params->>'max_value', '')::numeric, 0);
BEGIN
  -- ai_scope was built by ai_report_tool: the company's orders in the caller's branch scope.
  IF to_regclass('pg_temp.ai_fact') IS NOT NULL THEN DROP TABLE ai_fact; END IF;
  CREATE TEMP TABLE ai_fact ON COMMIT DROP AS
  WITH base AS (
    SELECT qi.quotation_item_id, qi.quotation_id, q.order_number, q.plate_number,
           s.created_at AS created_at, qi.created_at AS line_created_at,
           s.branch_name AS branch, s.branch_id,
           cb.city AS city,
           COALESCE((SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = cb.region_id),
                    (SELECT rg.region_code FROM qvm_new_apps.regions rg WHERE rg.region_id = cb.region_id)) AS region,
           (SELECT co2.name FROM qvm_new_apps.v_client_companies co2 WHERE co2.company_id = cb.list_data_id) AS company,
           (SELECT w.name FROM qvm_new_apps.v_client_workshops w WHERE w.workshop_id = cb.workshop_id) AS workshop,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = qi.main_brand) AS car_brand,
           NULLIF(btrim(qi.model), '') AS model, NULLIF(btrim(qi.year), '') AS year,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = qi.part_category) AS part_category,
           NULLIF(btrim(qi.part_number), '') AS part_number, NULLIF(btrim(qi.part_description), '') AS part,
           (SELECT ud.user_name FROM qvm_new_apps.user_data ud WHERE ud.user_id = q.service_advisor) AS service_advisor,
           (SELECT ud.user_name FROM qvm_new_apps.user_data ud WHERE ud.user_id = q.account_manager) AS account_manager,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = q.delivery_type) AS delivery_type,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = q.order_type) AS order_type,
           (SELECT ic.name FROM qvm_new_apps.insurance_companies ic
             WHERE ic.id = COALESCE(q.insurance_company_id, (SELECT ec.insurance_company_id FROM qvm_new_apps.end_customers ec WHERE ec.end_customer_id = q.end_customer_id))) AS insurance_company,
           (SELECT ec.name FROM qvm_new_apps.end_customers ec WHERE ec.end_customer_id = q.end_customer_id) AS end_customer,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = qi.item_status) AS item_status,
           qi.item_status AS item_status_id,
           qi.quantity, qi.price_before_vat::numeric AS unit_price, qi.estimated_price::numeric AS estimated_price,
           qi.discount_percent::numeric AS discount_percent,
           ci.confirmed_item_id, ci.approved_qty, ci.returned_qty,
           co.created_at AS confirmed_at,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = ci.cancellation_reason) AS cancellation_reason,
           (SELECT ld.list_data FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = ci.return_type) AS return_type,
           pi.purchase_item_id, pi.vendor_id, pi.vendor, pi.cost_unit, pi.receipt_status, pi.po_created_at,
           (SELECT min(d.delivery_date)::timestamptz FROM qvm_new_apps.delivery_items di JOIN qvm_new_apps.deliveries d ON d.delivery_id = di.delivery_id
             WHERE di.confirmed_item_id = ci.confirmed_item_id) AS delivered_at,
           EXISTS (SELECT 1 FROM qvm_new_apps.invoice_items ii WHERE ii.confirmed_item_id = ci.confirmed_item_id) AS invoiced,
           (SELECT COALESCE(sum(c.qty), 0) FROM qvm_new_apps.quotation_item_cancellations c WHERE c.quotation_item_id = qi.quotation_item_id) AS cancelled_qty,
           ofr.offers, ofr.min_offer, ofr.avg_offer, ofr.first_offer_at
      FROM ai_scope s
      JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = s.branch_id
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
      LEFT JOIN LATERAL (
        SELECT p.purchase_item_id, po.vendor_id, v.vendor_name AS vendor, COALESCE(p.final_purchase_price, qvi.cost)::numeric AS cost_unit,
               p.receipt_status, po.created_at AS po_created_at
          FROM qvm_new_apps.purchase_items p
          JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = p.purchase_order_id
          LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = p.cost_id
          LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id)
         WHERE p.confirmed_item_id = ci.confirmed_item_id
         ORDER BY p.created_at DESC LIMIT 1) pi ON true
      LEFT JOIN LATERAL (
        SELECT count(*) AS offers, min(o.cost)::numeric AS min_offer, avg(o.cost)::numeric AS avg_offer, min(o.created_at) AS first_offer_at
          FROM qvm_new_apps.quotation_vendor_items o
         WHERE o.quotation_item_id = qi.quotation_item_id AND COALESCE(o.cost, 0) > 0) ofr ON true
  )
  SELECT b.*,
         CASE v_date_field WHEN 'confirmed' THEN b.confirmed_at WHEN 'delivered' THEN b.delivered_at ELSE b.created_at END AS t,
         (b.confirmed_item_id IS NOT NULL) AS confirmed,
         COALESCE(b.unit_price, 0) * COALESCE(b.approved_qty, b.quantity, 1) AS line_value
    FROM base b
   WHERE (CASE v_date_field WHEN 'confirmed' THEN b.confirmed_at WHEN 'delivered' THEN b.delivered_at ELSE b.created_at END) >= p_from
     AND (CASE v_date_field WHEN 'confirmed' THEN b.confirmed_at WHEN 'delivered' THEN b.delivered_at ELSE b.created_at END) < p_to
     AND (v_vendor_ids IS NULL OR b.vendor_id = ANY(v_vendor_ids))
     AND (v_statuses IS NULL OR EXISTS (SELECT 1 FROM unnest(v_statuses) x WHERE lower(COALESCE(b.item_status, '')) LIKE '%' || x || '%'))
     AND (v_brands IS NULL OR EXISTS (SELECT 1 FROM unnest(v_brands) x WHERE lower(COALESCE(b.car_brand, '')) LIKE '%' || x || '%'))
     AND (v_cats IS NULL OR EXISTS (SELECT 1 FROM unnest(v_cats) x WHERE lower(COALESCE(b.part_category, '')) LIKE '%' || x || '%'))
     AND (v_dtypes IS NULL OR EXISTS (SELECT 1 FROM unnest(v_dtypes) x WHERE lower(COALESCE(b.delivery_type, '')) LIKE '%' || x || '%'))
     AND (v_otypes IS NULL OR EXISTS (SELECT 1 FROM unnest(v_otypes) x WHERE lower(COALESCE(b.order_type, '')) LIKE '%' || x || '%'))
     AND (v_min IS NULL OR COALESCE(b.unit_price, 0) * COALESCE(b.approved_qty, b.quantity, 1) >= v_min)
     AND (v_max IS NULL OR COALESCE(b.unit_price, 0) * COALESCE(b.approved_qty, b.quantity, 1) <= v_max)
     AND (p_search IS NULL OR b.order_number ILIKE '%' || p_search || '%' OR b.plate_number ILIKE '%' || p_search || '%'
          OR b.part_number ILIKE '%' || p_search || '%' OR b.part ILIKE '%' || p_search || '%'
          OR b.vendor ILIKE '%' || p_search || '%' OR b.end_customer ILIKE '%' || p_search || '%'
          OR qvm_new_apps.normalize_part_number(b.part_number) = qvm_new_apps.normalize_part_number(p_search));
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_build_fact(jsonb, timestamptz, timestamptz, text) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── the vocabulary ─────────────────────────────

-- Dimension name → SQL over the fact f. Only these fragments ever reach the query.
CREATE OR REPLACE FUNCTION qvm_new_apps.ai_dimension_sql(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_name
    WHEN 'branch' THEN 'f.branch' WHEN 'company' THEN 'f.company' WHEN 'workshop' THEN 'f.workshop'
    WHEN 'city' THEN 'f.city' WHEN 'region' THEN 'f.region' WHEN 'vendor' THEN 'f.vendor'
    WHEN 'car_brand' THEN 'f.car_brand' WHEN 'model' THEN 'f.model' WHEN 'year' THEN 'f.year'
    WHEN 'part_category' THEN 'f.part_category' WHEN 'part_number' THEN 'f.part_number' WHEN 'part' THEN 'f.part'
    WHEN 'service_advisor' THEN 'f.service_advisor' WHEN 'account_manager' THEN 'f.account_manager'
    WHEN 'delivery_type' THEN 'f.delivery_type' WHEN 'order_type' THEN 'f.order_type'
    WHEN 'insurance_company' THEN 'f.insurance_company' WHEN 'end_customer' THEN 'f.end_customer'
    WHEN 'item_status' THEN 'f.item_status' WHEN 'cancellation_reason' THEN 'f.cancellation_reason'
    WHEN 'return_type' THEN 'f.return_type' WHEN 'receipt_status' THEN 'f.receipt_status'
    WHEN 'order_number' THEN 'f.order_number'
    WHEN 'day' THEN 'to_char(date_trunc(''day'', f.t), ''YYYY-MM-DD'')'
    WHEN 'week' THEN 'to_char(date_trunc(''week'', f.t), ''YYYY-MM-DD'')'
    WHEN 'month' THEN 'to_char(date_trunc(''month'', f.t), ''YYYY-MM'')'
    WHEN 'quarter' THEN 'to_char(date_trunc(''quarter'', f.t), ''YYYY-"Q"Q'')'
    WHEN 'year_of' THEN 'to_char(date_trunc(''year'', f.t), ''YYYY'')'
    WHEN 'weekday' THEN 'to_char(f.t, ''Dy'')' WHEN 'hour' THEN 'to_char(f.t, ''HH24'')'
    ELSE NULL END;
$function$;

-- Measure name → aggregate SQL over the fact f.
CREATE OR REPLACE FUNCTION qvm_new_apps.ai_measure_sql(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_name
    WHEN 'lines' THEN 'count(*)'
    WHEN 'orders' THEN 'count(DISTINCT f.quotation_id)'
    WHEN 'confirmed_lines' THEN 'count(*) FILTER (WHERE f.confirmed)'
    WHEN 'confirmed_orders' THEN 'count(DISTINCT f.quotation_id) FILTER (WHERE f.confirmed)'
    WHEN 'open_lines' THEN 'count(*) FILTER (WHERE f.item_status_id NOT IN (18, 268, 31))'
    WHEN 'cancelled_lines' THEN 'count(*) FILTER (WHERE f.item_status_id IN (18, 268) OR f.cancelled_qty > 0)'
    WHEN 'delivered_lines' THEN 'count(*) FILTER (WHERE f.delivered_at IS NOT NULL OR f.item_status_id IN (23, 25, 26, 31))'
    WHEN 'invoiced_lines' THEN 'count(*) FILTER (WHERE f.invoiced)'
    WHEN 'settled_lines' THEN 'count(*) FILTER (WHERE f.item_status_id = 31)'
    WHEN 'returned_lines' THEN 'count(*) FILTER (WHERE COALESCE(f.returned_qty, 0) > 0)'
    WHEN 'received_lines' THEN 'count(*) FILTER (WHERE f.receipt_status = ''received'')'
    WHEN 'not_received_lines' THEN 'count(*) FILTER (WHERE f.purchase_item_id IS NOT NULL AND COALESCE(f.receipt_status, ''not_received'') <> ''received'')'
    WHEN 'discounted_lines' THEN 'count(*) FILTER (WHERE COALESCE(f.discount_percent, 0) > 0)'
    WHEN 'quantity' THEN 'sum(COALESCE(f.quantity, 0))'
    WHEN 'approved_qty' THEN 'sum(COALESCE(f.approved_qty, 0))'
    WHEN 'returned_qty' THEN 'sum(COALESCE(f.returned_qty, 0))'
    WHEN 'cancelled_qty' THEN 'sum(COALESCE(f.cancelled_qty, 0))'
    WHEN 'requested_value' THEN 'round(sum(COALESCE(f.unit_price, 0) * COALESCE(f.quantity, 1))::numeric, 2)'
    WHEN 'estimated_value' THEN 'round(sum(COALESCE(f.estimated_price, 0) * COALESCE(f.quantity, 1))::numeric, 2)'
    WHEN 'revenue_before_vat' THEN 'round(sum(COALESCE(f.unit_price, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed)::numeric, 2)'
    WHEN 'vat' THEN 'round((sum(COALESCE(f.unit_price, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed) * 0.15)::numeric, 2)'
    WHEN 'revenue_with_vat' THEN 'round((sum(COALESCE(f.unit_price, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed) * 1.15)::numeric, 2)'
    WHEN 'purchase_cost' THEN 'round(sum(COALESCE(f.cost_unit, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed)::numeric, 2)'
    WHEN 'margin' THEN 'round((sum(COALESCE(f.unit_price, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed) - sum(COALESCE(f.cost_unit, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed))::numeric, 2)'
    WHEN 'margin_pct' THEN 'round((100 * (1 - sum(COALESCE(f.cost_unit, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed) / NULLIF(sum(COALESCE(f.unit_price, 0) * COALESCE(f.approved_qty, 0)) FILTER (WHERE f.confirmed), 0)))::numeric, 1)'
    WHEN 'avg_unit_price' THEN 'round(avg(f.unit_price) FILTER (WHERE COALESCE(f.unit_price, 0) > 0)::numeric, 2)'
    WHEN 'avg_line_value' THEN 'round(avg(f.line_value)::numeric, 2)'
    WHEN 'avg_order_value' THEN 'round((sum(f.line_value) / NULLIF(count(DISTINCT f.quotation_id), 0))::numeric, 2)'
    WHEN 'avg_discount_pct' THEN 'round(avg(f.discount_percent) FILTER (WHERE COALESCE(f.discount_percent, 0) > 0)::numeric, 1)'
    WHEN 'offers' THEN 'sum(COALESCE(f.offers, 0))'
    WHEN 'avg_offer_cost' THEN 'round(avg(f.avg_offer)::numeric, 2)'
    WHEN 'min_offer_cost' THEN 'round(min(f.min_offer)::numeric, 2)'
    WHEN 'avg_offers_per_line' THEN 'round(avg(COALESCE(f.offers, 0))::numeric, 1)'
    WHEN 'avg_hours_to_confirm' THEN 'round((avg(EXTRACT(EPOCH FROM (f.confirmed_at - f.created_at))) / 3600)::numeric, 1)'
    WHEN 'median_hours_to_confirm' THEN 'round((percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (f.confirmed_at - f.created_at))) / 3600)::numeric, 1)'
    WHEN 'avg_hours_to_first_offer' THEN 'round((avg(EXTRACT(EPOCH FROM (f.first_offer_at - f.created_at))) / 3600)::numeric, 1)'
    WHEN 'avg_hours_to_purchase' THEN 'round((avg(EXTRACT(EPOCH FROM (f.po_created_at - f.confirmed_at))) / 3600)::numeric, 1)'
    WHEN 'avg_hours_to_deliver' THEN 'round((avg(EXTRACT(EPOCH FROM (f.delivered_at - f.confirmed_at))) / 3600)::numeric, 1)'
    WHEN 'avg_days_open' THEN 'round((avg(EXTRACT(EPOCH FROM (now() - f.created_at))) FILTER (WHERE f.item_status_id NOT IN (18, 268, 31)) / 86400)::numeric, 1)'
    ELSE NULL END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_query_vocabulary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- The names, then the values the small lists actually hold, so a filter is spelled as the data is.
  SELECT jsonb_agg(jsonb_build_object('kind', k, 'name', n, 'description', d) ORDER BY k, n) FROM (
    SELECT k, n, d FROM (VALUES
    ('dimension', 'branch', 'The client branch the order is for'), ('dimension', 'company', 'The client company'), ('dimension', 'workshop', 'The workshop the branch belongs to'),
    ('dimension', 'city', 'The branch city'), ('dimension', 'region', 'The branch region'), ('dimension', 'vendor', 'The vendor the line was bought from'),
    ('dimension', 'car_brand', 'The vehicle brand'), ('dimension', 'model', 'The vehicle model'), ('dimension', 'year', 'The vehicle year'),
    ('dimension', 'part_category', 'The part category'), ('dimension', 'part_number', 'The part number'), ('dimension', 'part', 'The part description'),
    ('dimension', 'service_advisor', 'The service advisor on the order'), ('dimension', 'account_manager', 'The account manager on the order'),
    ('dimension', 'delivery_type', 'Speed, same-day, standard…'), ('dimension', 'order_type', 'Service order, stock…'),
    ('dimension', 'insurance_company', 'The insurance company behind the order'), ('dimension', 'end_customer', 'The end customer the order is for'),
    ('dimension', 'item_status', 'The line status'), ('dimension', 'cancellation_reason', 'Why a line was cancelled'), ('dimension', 'return_type', 'How a line was returned'),
    ('dimension', 'receipt_status', 'received, lower_qty, not_received'), ('dimension', 'order_number', 'The order'),
    ('dimension', 'day', 'The date (of date_field)'), ('dimension', 'week', 'The week'), ('dimension', 'month', 'The month'), ('dimension', 'quarter', 'The quarter'),
    ('dimension', 'year_of', 'The year'), ('dimension', 'weekday', 'Mon…Sun'), ('dimension', 'hour', 'Hour of day 00–23'),
    ('measure', 'lines', 'Quotation lines'), ('measure', 'orders', 'Distinct orders'), ('measure', 'confirmed_lines', 'Lines confirmed'), ('measure', 'confirmed_orders', 'Orders with a confirmed line'),
    ('measure', 'open_lines', 'Lines neither settled nor cancelled'), ('measure', 'cancelled_lines', 'Lines cancelled'), ('measure', 'delivered_lines', 'Lines delivered'),
    ('measure', 'invoiced_lines', 'Lines on a customer invoice'), ('measure', 'settled_lines', 'Lines settled'), ('measure', 'returned_lines', 'Lines with a return'),
    ('measure', 'received_lines', 'Purchase lines received in full'), ('measure', 'not_received_lines', 'Purchase lines not fully received'), ('measure', 'discounted_lines', 'Lines carrying a discount'),
    ('measure', 'quantity', 'Requested quantity'), ('measure', 'approved_qty', 'Confirmed quantity'), ('measure', 'returned_qty', 'Quantity returned'), ('measure', 'cancelled_qty', 'Quantity cancelled'),
    ('measure', 'requested_value', 'Unit price × requested qty (before VAT)'), ('measure', 'estimated_value', 'Estimated price × requested qty'),
    ('measure', 'revenue_before_vat', 'Unit price × confirmed qty, confirmed lines'), ('measure', 'vat', '15% of revenue'), ('measure', 'revenue_with_vat', 'Revenue incl. VAT'),
    ('measure', 'purchase_cost', 'Purchase cost × confirmed qty'), ('measure', 'margin', 'Revenue − purchase cost'), ('measure', 'margin_pct', 'Margin as % of revenue'),
    ('measure', 'avg_unit_price', 'Average unit price'), ('measure', 'avg_line_value', 'Average line value'), ('measure', 'avg_order_value', 'Average value per order'),
    ('measure', 'avg_discount_pct', 'Average discount % on discounted lines'),
    ('measure', 'offers', 'Vendor offers received'), ('measure', 'avg_offer_cost', 'Average offered cost'), ('measure', 'min_offer_cost', 'Lowest offered cost'), ('measure', 'avg_offers_per_line', 'Offers per line'),
    ('measure', 'avg_hours_to_confirm', 'Request → confirmation'), ('measure', 'median_hours_to_confirm', 'Request → confirmation, median'),
    ('measure', 'avg_hours_to_first_offer', 'Request → first vendor offer'), ('measure', 'avg_hours_to_purchase', 'Confirmation → purchase order'),
    ('measure', 'avg_hours_to_deliver', 'Confirmation → delivery'), ('measure', 'avg_days_open', 'Age of still-open lines in days'),
    ('filter', 'date_field', 'created | confirmed | delivered — which date the range and the time dimensions use'),
    ('filter', 'vendor_ids', 'Only lines bought from these vendor ids'), ('filter', 'statuses', 'Only these line statuses (names)'),
    ('filter', 'car_brands', 'Only these vehicle brands (names)'), ('filter', 'part_categories', 'Only these part categories (names)'),
    ('filter', 'delivery_types', 'Only these delivery types (names)'), ('filter', 'order_types', 'Only these order types (names)'),
    ('filter', 'min_value', 'Only lines worth at least this (unit price × qty)'), ('filter', 'max_value', 'Only lines worth at most this'),
    ('filter', 'branch_ids', 'Only these branch ids'), ('filter', 'search', 'Order number, plate, part number, part name, vendor or end customer'),
    ('filter', 'sort_by', 'A measure name to order by (default: the first measure)'), ('filter', 'sort_dir', 'desc | asc')
    ) v(k, n, d)
    UNION ALL
    SELECT 'value: ' || l.list_name, ld.list_data, 'a ' || replace(l.list_name, '_', ' ') || ' name'
      FROM qvm_new_apps.list_data ld JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
     WHERE l.list_name IN ('delivery_type', 'order_type', 'item_status', 'part_category', 'return_type')
  ) all_rows;
$function$;

-- ───────────────────────────── the queries ─────────────────────────────

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_query_metrics(p_params jsonb, p_limit integer, OUT columns jsonb, OUT rows jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_dims text[] := CASE WHEN jsonb_typeof(p_params->'dimensions') = 'array' THEN ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'dimensions') x WHERE btrim(x) <> '') ELSE ARRAY[]::text[] END;
  v_measures text[] := CASE WHEN jsonb_typeof(p_params->'measures') = 'array' THEN ARRAY(SELECT lower(btrim(x)) FROM jsonb_array_elements_text(p_params->'measures') x WHERE btrim(x) <> '') ELSE ARRAY[]::text[] END;
  v_sort text := lower(NULLIF(btrim(COALESCE(p_params->>'sort_by', '')), ''));
  v_dir text := CASE WHEN lower(COALESCE(p_params->>'sort_dir', '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;
  v_sel text := ''; v_grp text := ''; v_cols text[] := ARRAY[]::text[]; v_ord text; d text; m text; i integer := 0; v_sql text;
BEGIN
  IF array_length(v_dims, 1) > 2 THEN RAISE EXCEPTION 'query_metrics takes at most two dimensions'; END IF;
  IF COALESCE(array_length(v_measures, 1), 0) = 0 THEN v_measures := ARRAY['lines']; END IF;
  IF array_length(v_measures, 1) > 8 THEN RAISE EXCEPTION 'query_metrics takes at most eight measures'; END IF;
  FOREACH d IN ARRAY v_dims LOOP
    IF qvm_new_apps.ai_dimension_sql(d) IS NULL THEN RAISE EXCEPTION 'Unknown dimension %; ask the vocabulary tool', d; END IF;
    i := i + 1;
    v_sel := v_sel || format('COALESCE(%s::text, ''—'') AS %I, ', qvm_new_apps.ai_dimension_sql(d), d);
    v_grp := v_grp || CASE WHEN i > 1 THEN ', ' ELSE '' END || i::text;
    v_cols := v_cols || d;
  END LOOP;
  FOREACH m IN ARRAY v_measures LOOP
    IF qvm_new_apps.ai_measure_sql(m) IS NULL THEN RAISE EXCEPTION 'Unknown measure %; ask the vocabulary tool', m; END IF;
    v_sel := v_sel || format('%s AS %I, ', qvm_new_apps.ai_measure_sql(m), m);
    v_cols := v_cols || m;
  END LOOP;
  v_sel := left(v_sel, length(v_sel) - 2);
  -- Order by the asked measure, else the first; a time dimension orders by itself instead.
  IF v_sort IS NOT NULL AND v_sort = ANY(v_measures) THEN v_ord := format('%I %s NULLS LAST', v_sort, v_dir);
  ELSIF v_dims[1] IN ('day', 'week', 'month', 'quarter', 'year_of', 'hour') THEN v_ord := format('%I ASC', v_dims[1]);
  ELSE v_ord := format('%I %s NULLS LAST', v_measures[1], v_dir); END IF;
  v_sql := format('SELECT COALESCE(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) FROM (SELECT %s FROM ai_fact f %s ORDER BY %s LIMIT %s) x',
                  v_sel, CASE WHEN v_grp <> '' THEN 'GROUP BY ' || v_grp ELSE '' END, v_ord, p_limit);
  EXECUTE v_sql INTO rows;
  columns := to_jsonb(v_cols);
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_query_metrics(jsonb, integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.ai_query_lines(p_params jsonb, p_limit integer, OUT columns jsonb, OUT rows jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  columns := '["order_number","branch","created_on","part_number","part","car_brand","qty","unit_price","line_value","status","vendor","confirmed_on","delivered_on"]';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_number', f.order_number, 'branch', f.branch, 'created_on', to_char(f.created_at, 'YYYY-MM-DD'),
           'part_number', COALESCE(f.part_number, '—'), 'part', COALESCE(f.part, '—'), 'car_brand', f.car_brand,
           'qty', COALESCE(f.approved_qty, f.quantity), 'unit_price', round(COALESCE(f.unit_price, 0), 2), 'line_value', round(f.line_value, 2),
           'status', COALESCE(f.item_status, 'Unknown'), 'vendor', f.vendor,
           'confirmed_on', to_char(f.confirmed_at, 'YYYY-MM-DD'), 'delivered_on', to_char(f.delivered_at, 'YYYY-MM-DD'))
         ORDER BY f.created_at DESC, f.quotation_item_id DESC), '[]'::jsonb)
    INTO rows
    FROM (SELECT * FROM ai_fact f ORDER BY f.created_at DESC, f.quotation_item_id DESC LIMIT p_limit) f;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.ai_query_lines(jsonb, integer) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── the tool, with the three new names ─────────────────────────────

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
  -- A text filter: an order number, a plate or a part number. Empty means none.
  v_search text := NULLIF(btrim(COALESCE(p_params->>'search', '')), '');
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

    WHEN 'open_orders' THEN
      -- The orders still in flight: at least one line neither settled nor cancelled. Newest first.
      v_columns := '["order_number","branch","created_on","age_days","lines","open_lines","status","value_before_vat"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('order_number', x.order_number, 'branch', x.branch, 'created_on', x.created_on, 'age_days', x.age_days, 'lines', x.lines, 'open_lines', x.open_lines, 'status', x.status, 'value_before_vat', x.value_before_vat) ORDER BY x.created_at DESC), '[]') INTO v_rows
        FROM (SELECT q.order_number, s.branch_name AS branch, s.created_at, to_char(s.created_at, 'YYYY-MM-DD') AS created_on,
                     (EXTRACT(EPOCH FROM (now() - s.created_at)) / 86400)::int AS age_days,
                     count(qi.quotation_item_id) AS lines,
                     count(qi.quotation_item_id) FILTER (WHERE qi.item_status NOT IN (18, 268, 31)) AS open_lines,
                     (SELECT ld.list_data FROM qvm_new_apps.quotation_items q2 JOIN qvm_new_apps.list_data ld ON ld.list_data_id = q2.item_status
                       WHERE q2.quotation_id = s.quotation_id AND q2.item_status NOT IN (18, 268, 31) GROUP BY ld.list_data ORDER BY count(*) DESC LIMIT 1) AS status,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(qi.quantity, 1))::numeric, 2) AS value_before_vat
                FROM ai_scope s JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
                 AND (v_search IS NULL OR q.order_number ILIKE '%' || v_search || '%' OR q.plate_number ILIKE '%' || v_search || '%')
               GROUP BY q.order_number, s.branch_name, s.created_at, s.quotation_id
              HAVING count(qi.quotation_item_id) FILTER (WHERE qi.item_status NOT IN (18, 268, 31)) > 0
               ORDER BY s.created_at DESC LIMIT v_limit) x;

    WHEN 'order_lines' THEN
      -- The lines themselves, for one order or one part when search names it; newest first.
      v_columns := '["order_number","branch","part_number","part","brand","qty","unit_price","status","created_on"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('order_number', x.order_number, 'branch', x.branch, 'part_number', x.part_number, 'part', x.part, 'brand', x.brand, 'qty', x.qty, 'unit_price', x.unit_price, 'status', x.status, 'created_on', x.created_on) ORDER BY x.created_at DESC, x.quotation_item_id DESC), '[]') INTO v_rows
        FROM (SELECT q.order_number, s.branch_name AS branch, COALESCE(NULLIF(btrim(qi.part_number), ''), '—') AS part_number,
                     COALESCE(NULLIF(btrim(qi.part_description), ''), '—') AS part, ld_b.list_data AS brand, qi.quantity AS qty,
                     round(COALESCE(qi.price_before_vat, 0)::numeric, 2) AS unit_price, COALESCE(ld.list_data, 'Unknown') AS status,
                     to_char(qi.created_at, 'YYYY-MM-DD') AS created_on, qi.created_at, qi.quotation_item_id
                FROM ai_scope s JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
                LEFT JOIN qvm_new_apps.list_data ld_b ON ld_b.list_data_id = qi.main_brand
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
                 AND (v_search IS NULL OR q.order_number ILIKE '%' || v_search || '%'
                      OR qvm_new_apps.normalize_part_number(qi.part_number) = qvm_new_apps.normalize_part_number(v_search)
                      OR qi.part_number ILIKE '%' || v_search || '%')
               ORDER BY qi.created_at DESC LIMIT v_limit) x;

    WHEN 'requests_by_car_brand' THEN
      v_columns := '["car_brand","lines","orders","confirmed_lines","value_before_vat"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('car_brand', x.car_brand, 'lines', x.lines, 'orders', x.orders, 'confirmed_lines', x.confirmed_lines, 'value_before_vat', x.value_before_vat) ORDER BY x.lines DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Unknown') AS car_brand, count(*) AS lines, count(DISTINCT qi.quotation_id) AS orders,
                     count(ci.confirmed_item_id) AS confirmed_lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, 0))::numeric, 2) AS value_before_vat
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 ORDER BY 2 DESC LIMIT v_limit) x;

    WHEN 'orders_by_service_advisor' THEN
      v_columns := '["service_advisor","orders","lines","confirmed_orders","confirmed_value"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('service_advisor', x.service_advisor, 'orders', x.orders, 'lines', x.lines, 'confirmed_orders', x.confirmed_orders, 'confirmed_value', x.confirmed_value) ORDER BY x.orders DESC), '[]') INTO v_rows
        FROM (SELECT COALESCE(ud.user_name, 'Unassigned') AS service_advisor, count(DISTINCT s.quotation_id) AS orders, count(qi.quotation_item_id) AS lines,
                     count(DISTINCT co.confirmed_order_id) AS confirmed_orders,
                     round(sum(COALESCE(qi.price_before_vat, 0) * ci.approved_qty) FILTER (WHERE ci.confirmed_item_id IS NOT NULL)::numeric, 2) AS confirmed_value
                FROM ai_scope s JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = q.service_advisor
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 ORDER BY 2 DESC LIMIT v_limit) x;

    WHEN 'spend_by_part_category' THEN
      v_columns := '["part_category","lines","quantity","value_before_vat","purchase_cost"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('part_category', x.part_category, 'lines', x.lines, 'quantity', x.quantity, 'value_before_vat', x.value_before_vat, 'purchase_cost', x.purchase_cost) ORDER BY x.value_before_vat DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT COALESCE(ld.list_data, 'Uncategorised') AS part_category, count(*) AS lines, sum(COALESCE(ci.approved_qty, qi.quantity, 1)) AS quantity,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS value_before_vat,
                     round(sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS purchase_cost
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.part_category
                LEFT JOIN LATERAL (SELECT p.final_purchase_price, p.cost_id FROM qvm_new_apps.purchase_items p WHERE p.confirmed_item_id = ci.confirmed_item_id ORDER BY p.created_at DESC LIMIT 1) pi ON true
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = COALESCE(pi.cost_id, qi.cost_id)
               WHERE co.created_at >= r.date_from AND co.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'margin_by_vendor' THEN
      -- Revenue and cost on the same bought lines, by the vendor they were bought from.
      v_columns := '["vendor","lines","revenue_before_vat","purchase_cost","margin","margin_pct"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'lines', x.lines, 'revenue_before_vat', x.revenue_before_vat, 'purchase_cost', x.purchase_cost, 'margin', x.margin, 'margin_pct', x.margin_pct) ORDER BY x.revenue_before_vat DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS lines,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1))::numeric, 2) AS revenue_before_vat,
                     round(sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1))::numeric, 2) AS purchase_cost,
                     round((sum(COALESCE(qi.price_before_vat, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1)) - sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1)))::numeric, 2) AS margin,
                     round((100 * (1 - sum(COALESCE(pi.final_purchase_price, qvi.cost, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1)) / NULLIF(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(pi.approved_qty, ci.approved_qty, 1)), 0)))::numeric, 1) AS margin_pct
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.purchase_items pi ON pi.purchase_order_id = po.purchase_order_id
                JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
                JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id)
               WHERE po.created_at >= r.date_from AND po.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'discounts_summary' THEN
      v_columns := '["branch","lines","discounted_lines","avg_discount_pct","max_discount_pct","value_before_vat"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('branch', x.branch, 'lines', x.lines, 'discounted_lines', x.discounted_lines, 'avg_discount_pct', x.avg_discount_pct, 'max_discount_pct', x.max_discount_pct, 'value_before_vat', x.value_before_vat) ORDER BY x.discounted_lines DESC), '[]') INTO v_rows
        FROM (SELECT s.branch_name AS branch, count(*) AS lines, count(*) FILTER (WHERE COALESCE(qi.discount_percent, 0) > 0) AS discounted_lines,
                     round(avg(qi.discount_percent) FILTER (WHERE COALESCE(qi.discount_percent, 0) > 0)::numeric, 1) AS avg_discount_pct,
                     round(max(COALESCE(qi.discount_percent, 0))::numeric, 1) AS max_discount_pct,
                     round(sum(COALESCE(qi.price_before_vat, 0) * COALESCE(ci.approved_qty, qi.quantity, 1))::numeric, 2) AS value_before_vat
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'vat_summary' THEN
      -- Customer invoices per period: what was billed, the VAT in it, and what has been paid.
      v_columns := '["period","invoices","subtotal","vat","total","paid"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('period', x.period, 'invoices', x.invoices, 'subtotal', x.subtotal, 'vat', x.vat, 'total', x.total, 'paid', x.paid) ORDER BY x.period), '[]') INTO v_rows
        FROM (SELECT to_char(date_trunc(CASE WHEN p_params->>'bucket' IN ('day', 'week') THEN v_bucket ELSE 'month' END, i.created_at), 'YYYY-MM-DD') AS period, count(*) AS invoices,
                     round(sum(COALESCE(i.subtotal, 0))::numeric, 2) AS subtotal, round(sum(COALESCE(i.vat, 0))::numeric, 2) AS vat,
                     round(sum(COALESCE(i.total, 0))::numeric, 2) AS total, round(sum(COALESCE(i.paid_amount, 0))::numeric, 2) AS paid
                FROM ai_scope s JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = s.quotation_id
                JOIN qvm_new_apps.invoices i ON i.confirmed_order_id = co.confirmed_order_id
               WHERE i.created_at >= r.date_from AND i.created_at < r.date_to
               GROUP BY 1 ORDER BY 1 LIMIT v_limit) x;

    WHEN 'part_price_history' THEN
      -- One part's offers over time, by vendor: search must name the part number.
      IF v_search IS NULL THEN RAISE EXCEPTION 'part_price_history needs search = the part number'; END IF;
      v_columns := '["period","vendor","offers","min_cost","avg_cost","max_cost","avg_customer_price"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('period', x.period, 'vendor', x.vendor, 'offers', x.offers, 'min_cost', x.min_cost, 'avg_cost', x.avg_cost, 'max_cost', x.max_cost, 'avg_customer_price', x.avg_customer_price) ORDER BY x.period, x.vendor), '[]') INTO v_rows
        FROM (SELECT to_char(date_trunc('month', qvi.created_at), 'YYYY-MM') AS period, COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS offers,
                     round(min(qvi.cost)::numeric, 2) AS min_cost, round(avg(qvi.cost)::numeric, 2) AS avg_cost, round(max(qvi.cost)::numeric, 2) AS max_cost,
                     round(avg(qi.price_before_vat) FILTER (WHERE COALESCE(qi.price_before_vat, 0) > 0)::numeric, 2) AS avg_customer_price
                FROM ai_scope s JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = s.quotation_id
                JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.quotation_item_id = qi.quotation_item_id AND COALESCE(qvi.cost, 0) > 0
                LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
               WHERE s.created_at >= r.date_from AND s.created_at < r.date_to
                 AND (qvm_new_apps.normalize_part_number(qi.part_number) = qvm_new_apps.normalize_part_number(v_search)
                      OR qvm_new_apps.normalize_part_number(qvi.alternative_part_number) = qvm_new_apps.normalize_part_number(v_search))
               GROUP BY 1, 2 ORDER BY 1, 2 LIMIT v_limit) x;

    WHEN 'stock_value_by_vendor' THEN
      -- The vendors' stock files as they stand now: parts, units and their value at wholesale and retail.
      v_columns := '["vendor","parts","available_parts","units","wholesale_value","retail_value"]';
      SELECT COALESCE(jsonb_agg(jsonb_build_object('vendor', x.vendor, 'parts', x.parts, 'available_parts', x.available_parts, 'units', x.units, 'wholesale_value', x.wholesale_value, 'retail_value', x.retail_value) ORDER BY x.wholesale_value DESC NULLS LAST), '[]') INTO v_rows
        FROM (SELECT COALESCE(v.vendor_name, 'Unknown') AS vendor, count(*) AS parts, count(*) FILTER (WHERE st.is_available) AS available_parts,
                     sum(COALESCE(st.quantity, 0)) AS units,
                     round(sum(COALESCE(st.quantity, 0) * COALESCE(st.wholesale_price, 0))::numeric, 2) AS wholesale_value,
                     round(sum(COALESCE(st.quantity, 0) * COALESCE(st.retail_price, 0))::numeric, 2) AS retail_value
                FROM qvm_new_apps.inventory_stock st LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = st.vendor_id
               WHERE (v_search IS NULL OR v.vendor_name ILIKE '%' || v_search || '%')
               GROUP BY 1 LIMIT v_limit) x;

    WHEN 'query_metrics' THEN
      -- Any measures by any one or two dimensions, with filters: the general tool behind every report
      -- a named tool does not already answer. The vocabulary is fixed in ai_query_vocabulary.
      PERFORM qvm_new_apps.ai_build_fact(p_params, r.date_from, r.date_to, v_search);
      SELECT q.columns, q.rows INTO v_columns, v_rows FROM qvm_new_apps.ai_query_metrics(p_params, v_limit) q;

    WHEN 'query_lines' THEN
      -- The lines behind any such report, with the same filters, newest first.
      PERFORM qvm_new_apps.ai_build_fact(p_params, r.date_from, r.date_to, v_search);
      SELECT q.columns, q.rows INTO v_columns, v_rows FROM qvm_new_apps.ai_query_lines(p_params, v_limit) q;

    WHEN 'vocabulary' THEN
      -- What query_metrics and query_lines understand: for a client that cannot read the catalogue.
      v_columns := '["kind","name","description"]';
      v_rows := qvm_new_apps.ai_query_vocabulary();

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

-- The recipe check knows the new names.
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
    IF COALESCE(s->>'tool', '') NOT IN ('requests_by_status', 'requests_over_time', 'confirmation_time_by_branch', 'vendor_response_times', 'purchase_totals_by_vendor', 'order_value_by_branch', 'top_parts', 'returns_summary', 'account_manager_workload', 'delivery_pipeline', 'delivery_lead_time', 'orders_by_delivery_type', 'orders_by_order_type', 'purchase_cycle_time', 'supplier_invoice_lag', 'invoicing_status', 'invoice_aging', 'sales_vs_cost_margin', 'margin_over_time', 'cancellations_summary', 'vendor_fill_rate', 'vendor_price_rank', 'extract_pn_turnaround', 'tendering_turnaround', 'branch_overview', 'monthly_summary', 'stock_coverage', 'approvals_summary', 'shipments_summary', 'receipt_status_by_vendor',
                                        'open_orders', 'order_lines', 'requests_by_car_brand', 'orders_by_service_advisor', 'spend_by_part_category', 'margin_by_vendor', 'discounts_summary', 'vat_summary', 'part_price_history', 'stock_value_by_vendor', 'query_metrics', 'query_lines', 'vocabulary') THEN
      RAISE EXCEPTION 'Section % names an unknown tool %', n, s->>'tool';
    END IF;
    IF COALESCE(s->>'visual', '') NOT IN ('kpi', 'bar', 'line', 'table') THEN
      RAISE EXCEPTION 'Section % names an unknown visual %', n, s->>'visual';
    END IF;
    IF s ? 'params' AND jsonb_typeof(s->'params') <> 'object' THEN RAISE EXCEPTION 'Section % has malformed params', n; END IF;
  END LOOP;
END $function$;

