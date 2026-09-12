-- The same fix for the dashboards that carry their scope in a plpgsql variable.
--
-- Same fault, different shape: `v_is_internal OR ...` waves through every internal account. The
-- internal branch of each filter now also has to be inside the account's scope, with NULL still
-- meaning unrestricted.

CREATE OR REPLACE FUNCTION public.get_orders_with_item_status(p_status_id integer, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_user_id uuid;
  v_user_type int;
  v_user_branch int;
  v_is_internal boolean;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope integer[];
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  -- This function had no access control at all: it accepted p_user_id, assigned it here and never
  -- looked at it again, so every caller saw every order from every company. A client user is now
  -- held to their own branch. Reading the branch straight off quotation_items is safe because a
  -- quotation never spans two customers.
  SELECT ud.user_type, ud.user_branch
    INTO v_user_type, v_user_branch
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_id = v_user_id;

  v_is_internal := (v_user_type = 185);
  v_scope := qvm_new_apps.get_internal_branch_scope(p_user_id);

  SELECT jsonb_build_object(
    'status', 'success',
    'total_count', (SELECT COUNT(DISTINCT q.quotation_id)
                  FROM qvm_new_apps.quotation_items qi
                  JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
                  WHERE qi.item_status = p_status_id
                    AND ((v_is_internal AND (v_scope IS NULL OR qi.customer_id = ANY(v_scope)))
               OR qi.customer_id = v_user_branch)),
    'data', COALESCE(jsonb_agg(order_obj ORDER BY order_obj->>'created_at' DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_id', q.quotation_id,
      'order_number', q.order_number,
      'created_at', q.created_at,
      'account_manager', q.account_manager,
      'service_advisor', q.service_advisor,
      'customer_id', first_item.customer_id,
      'branch_name', cb.branch_name,
      'client_company', ld.list_data,
      'plate_number', q.plate_number,
      'vin', first_item.vin,
      'brand', COALESCE(vb.list_data, ''),
      'model', first_item.model,
      'items_count', item_counts.items_count,
      'items', items_json.items
    ) AS order_obj
    FROM (
      SELECT DISTINCT q.quotation_id
      FROM qvm_new_apps.quotation_items qi
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
      WHERE qi.item_status = p_status_id
        AND ((v_is_internal AND (v_scope IS NULL OR qi.customer_id = ANY(v_scope)))
               OR qi.customer_id = v_user_branch)
      LIMIT GREATEST(1, COALESCE(p_limit, 100))
      OFFSET GREATEST(0, COALESCE(p_offset, 0))
    ) o
    JOIN qvm_new_apps.quotations q ON q.quotation_id = o.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.quotation_item_id, qi.customer_id, qi.part_description, qi.part_number, qi.vin, qi.main_brand, qi.model
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = o.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_item ON true
    LEFT JOIN qvm_new_apps.list_data vb ON vb.list_data_id = first_item.main_brand
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS items_count
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = o.quotation_id AND qi.item_status = p_status_id
    ) item_counts ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'quotation_item_id', qi.quotation_item_id,
        'part_number', COALESCE(ci.final_part_number, qi.part_number),
        'part_description', qi.part_description,
        'quantity', qi.quantity,
        'approved_qty', COALESCE(ci.approved_qty, qi.quantity),
        'price_before_vat', COALESCE(qi.price_before_vat, 0),
        'vat', 15,
        'discount_percent', COALESCE(qi.discount_percent, 0),
        'brand_class', COALESCE(bcls.list_data, '')
      ) ORDER BY qi.quotation_item_id), '[]'::jsonb) AS items
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data bcls ON bcls.list_data_id = COALESCE(ci.final_brand_class, qi.brand_class)
      WHERE qi.quotation_id = o.quotation_id AND qi.item_status = p_status_id
    ) items_json ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_item.customer_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = cb.list_data_id
  ) sub;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_delivered_orders_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_company_id integer DEFAULT NULL::integer, p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'event_date'::text, p_sort_order text DEFAULT 'desc'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope integer[];
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
    INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);
  v_scope := qvm_new_apps.get_internal_branch_scope(p_user_id);

  WITH dn_items_agg AS (
    SELECT
      di.delivery_id,
      qi.customer_id AS branch_id,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty), 0) AS total_before_vat,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty * 1.15), 0) AS total_with_vat,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty * 0.15), 0) AS vat_amount,
      MAX(CASE WHEN ci.item_status NOT IN (28, 29, 30, 214, 215) THEN ci.item_status END) AS base_item_status_id,
      MAX(CASE WHEN ci.item_status NOT IN (28, 29, 30, 214, 215) THEN ld_status.list_data END) AS base_item_status_label,
      MAX(ci.item_status) AS fallback_item_status_id,
      MAX(ld_status.list_data) AS fallback_item_status_label,
      BOOL_OR(ci.item_status IN (213, 25)) AS has_pending_item_status,
      BOOL_OR(di.invoice_id IS NOT NULL) AS has_invoice
    FROM qvm_new_apps.delivery_items di
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    GROUP BY di.delivery_id, qi.customer_id
  ),
  dn_base AS (
    SELECT DISTINCT ON (d.delivery_id, cb.customer_id)
      'DN'::text AS note_type,
      d.delivery_id::text AS note_id,
      q.order_number,
      co.created_at AS order_date,
      d.client_po,
      d.delivery_date AS event_date,
      q.plate_number,
      vehicle_info.vin,
      vehicle_info.brand,
      vehicle_info.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      d.signature,
      d.signature_uuid,
      u.user_name AS signed_by,
      inv.invoice_number,
      d.shipping_price,
      q.shipping_type,
      dia.total_before_vat,
      dia.total_with_vat,
      dia.vat_amount,
      COALESCE(dia.base_item_status_id, dia.fallback_item_status_id) AS item_status_id,
      COALESCE(dia.base_item_status_label, dia.fallback_item_status_label) AS item_status_label,
      dia.has_pending_item_status,
      dia.has_invoice
    FROM qvm_new_apps.deliveries d
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = d.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.delivery_items di ON di.delivery_id = d.delivery_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN dn_items_agg dia ON dia.delivery_id = d.delivery_id AND dia.branch_id = cb.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = d.signature_uuid
      LEFT JOIN LATERAL (
        SELECT i.invoice_number
        FROM qvm_new_apps.invoices i
        WHERE i.confirmed_order_id = co.confirmed_order_id
        ORDER BY i.created_at DESC
        LIMIT 1
      ) inv ON true
      LEFT JOIN LATERAL (
        SELECT
          qi2.vin AS vin,
          ld_brand2.list_data AS brand,
          qi2.model AS model
        FROM qvm_new_apps.quotation_items qi2
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        WHERE qi2.quotation_id = q.quotation_id
          AND qi2.customer_id = cb.customer_id
        ORDER BY qi2.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
    WHERE
      (p_date_from IS NULL OR d.delivery_date >= p_date_from)
      AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
      AND (
        (v_is_internal AND (v_scope IS NULL OR cb.customer_id = ANY(v_scope)))
        OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
    ORDER BY d.delivery_id, cb.customer_id
  ),
  rn_items_agg AS (
    SELECT
      ri.return_id,
      qi.customer_id AS branch_id,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty), 0) AS total_before_vat,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty * 1.15), 0) AS total_with_vat,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty * 0.15), 0) AS vat_amount,
      MAX(ci.item_status) AS item_status_id,
      MAX(ld_status.list_data) AS item_status_label,
      BOOL_OR(ci.item_status IN (214, 215)) AS has_pending_item_status,
      BOOL_OR(ri.creditnote_id IS NOT NULL) AS has_creditnote
    FROM qvm_new_apps.return_items ri
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    GROUP BY ri.return_id, qi.customer_id
  ),
  rn_base AS (
    SELECT DISTINCT ON (r.return_id, cb.customer_id)
      'RN'::text AS note_type,
      r.return_id::text AS note_id,
      q.order_number,
      co.created_at AS order_date,
      r.referenced_client_po,
      r.return_date::timestamp with time zone AS event_date,
      q.plate_number,
      vehicle_info.vin,
      vehicle_info.brand,
      vehicle_info.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      r.signature,
      r.signature_uuid,
      u.user_name AS signed_by,
      cr.creditnote_number,
      r.shipping_price,
      q.shipping_type,
      ria.total_before_vat,
      ria.total_with_vat,
      ria.vat_amount,
      ria.item_status_id,
      ria.item_status_label,
      ria.has_pending_item_status,
      ria.has_creditnote
    FROM qvm_new_apps.returns r
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = r.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.return_items ri ON ri.return_id = r.return_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN rn_items_agg ria ON ria.return_id = r.return_id AND ria.branch_id = cb.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = r.signature_uuid
      LEFT JOIN LATERAL (
        SELECT c.creditnote_number
        FROM qvm_new_apps.creditnotes c
        WHERE c.confirmed_order_id = co.confirmed_order_id
        ORDER BY c.created_at DESC
        LIMIT 1
      ) cr ON true
      LEFT JOIN LATERAL (
        SELECT
          qi2.vin AS vin,
          ld_brand2.list_data AS brand,
          qi2.model AS model
        FROM qvm_new_apps.quotation_items qi2
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        WHERE qi2.quotation_id = q.quotation_id
          AND qi2.customer_id = cb.customer_id
        ORDER BY qi2.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
    WHERE
      (p_date_from IS NULL OR r.return_date >= p_date_from)
      AND (p_date_to IS NULL OR r.return_date <= p_date_to)
      AND (
        (v_is_internal AND (v_scope IS NULL OR cb.customer_id = ANY(v_scope)))
        OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
    ORDER BY r.return_id, cb.customer_id
  ),
  combined AS (
    SELECT
      note_type,
      note_id,
      order_number,
      order_date,
      client_po,
      event_date,
      plate_number,
      vin,
      brand,
      model,
      client_company_id,
      client_company,
      branch_id,
      branch_name,
      signature,
      signature_uuid,
      signed_by,
      invoice_number,
      NULL::text AS creditnote_number,
      shipping_price,
      shipping_type,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_invoice AS has_doc,
      item_status_id,
      COALESCE(
        item_status_label,
        CASE
          WHEN (signature IS NULL OR signature = '') THEN 'DN Sign Pending'
          WHEN NOT has_invoice THEN 'Pending Invoice'
          ELSE 'Invoice Issued'
        END
      ) AS status
    FROM dn_base
    UNION ALL
    SELECT
      note_type,
      note_id,
      order_number,
      order_date,
      referenced_client_po,
      event_date,
      plate_number,
      vin,
      brand,
      model,
      client_company_id,
      client_company,
      branch_id,
      branch_name,
      signature,
      signature_uuid,
      signed_by,
      NULL::text AS invoice_number,
      creditnote_number,
      shipping_price,
      shipping_type,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_creditnote AS has_doc,
      item_status_id,
      COALESCE(
        item_status_label,
        CASE
          WHEN (signature IS NULL OR signature = '') THEN 'RN Sign Pending'
          WHEN NOT has_creditnote THEN 'Pending Credit Note'
          ELSE 'Credit Note Issued'
        END
      ) AS status
    FROM rn_base
  ),
  filtered AS (
    SELECT *
    FROM combined
    WHERE
      (p_status IS NULL OR status = p_status)
      AND (
        (note_type = 'DN' AND (
          item_status_id IN (25, 213)
          OR (
            item_status_id = 26
            AND (signature IS NULL OR signature = '' OR NOT has_doc)
          )
        ))
        OR (note_type = 'RN' AND (
          item_status_id IN (214, 215)
          OR (
            item_status_id = 30
            AND (signature IS NULL OR signature = '' OR NOT has_doc)
          )
        ))
      )
      AND (
        p_search IS NULL
        OR order_number ILIKE '%' || p_search || '%'
        OR plate_number ILIKE '%' || p_search || '%'
        OR vin ILIKE '%' || p_search || '%'
        OR brand ILIKE '%' || p_search || '%'
        OR model ILIKE '%' || p_search || '%'
      )
      AND (
        NOT v_is_internal
        OR (p_company_id IS NULL OR client_company_id = p_company_id)
      )
      AND (
        NOT v_is_internal
        OR (p_branch_id IS NULL OR branch_id = p_branch_id)
      )
  ),
  paged AS (
    SELECT *
    FROM filtered
    ORDER BY
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'asc' THEN COALESCE(event_date, order_date) END ASC,
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'desc' THEN COALESCE(event_date, order_date) END DESC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN total_before_vat END ASC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN total_before_vat END DESC,
      COALESCE(event_date, order_date) DESC,
      note_id DESC
    LIMIT p_limit
    OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Delivered notes fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered),
    'data',
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', note_id,
            'type', note_type,
            'status', status,
            'orderNumber', order_number,
            'orderDate', order_date,
            'poNumber', client_po,
            'eventDate', event_date,
            'plateNumber', plate_number,
            'vin', vin,
            'brand', brand,
            'model', model,
            'client', client_company,
            'branch', branch_name,
            'totalBeforeVat', COALESCE(dn_items.total_before_vat, rn_items.total_before_vat, 0),
            'vatAmount', COALESCE(dn_items.vat_amount, rn_items.vat_amount, 0),
            'totalWithVat', COALESCE(dn_items.total_with_vat, rn_items.total_with_vat, 0),
            'shippingFees', COALESCE(shipping_price, 0),
            'shippingType', shipping_type,
            'signature', signature,
            'signedBy', signed_by,
            'signedAt', NULL,
            'invoiceNumber', invoice_number,
            'creditNoteNumber', creditnote_number,
            'items', COALESCE(dn_items.items, rn_items.items, '[]'::jsonb)
          )
        ),
        '[]'::jsonb
      )
  )
  INTO v_result
  FROM paged
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'id', ci2.confirmed_item_id::text,
              'partNumber', qi2.part_number,
              'description', qi2.part_description,
              'brand', ld_brand2.list_data,
              'brandClass', ld_brand_class2.list_data,
              'quantity', di2.delivered_qty,
              'priceBeforeVat', qi2.price_before_vat,
              'totalWithVat', (qi2.price_before_vat * di2.delivered_qty * 1.15),
              'vatAmount', (qi2.price_before_vat * di2.delivered_qty * 0.15)
            )
            ORDER BY di2.delivery_item_id
          ),
          '[]'::jsonb
        ) AS items,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty), 0) AS total_before_vat,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty * 1.15), 0) AS total_with_vat,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty * 0.15), 0) AS vat_amount
      FROM qvm_new_apps.delivery_items di2
      JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = di2.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
      LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
      WHERE di2.delivery_id = paged.note_id::integer
        AND qi2.customer_id = paged.branch_id
        AND paged.note_type = 'DN'
    ) dn_items ON paged.note_type = 'DN'
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'id', ci2.confirmed_item_id::text,
              'partNumber', qi2.part_number,
              'description', qi2.part_description,
              'brand', ld_brand2.list_data,
              'brandClass', ld_brand_class2.list_data,
              'quantity', ri2.return_qty,
              'priceBeforeVat', qi2.price_before_vat,
              'totalWithVat', (qi2.price_before_vat * ri2.return_qty * 1.15),
              'vatAmount', (qi2.price_before_vat * ri2.return_qty * 0.15)
            )
            ORDER BY ri2.return_item_id
          ),
          '[]'::jsonb
        ) AS items,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty), 0) AS total_before_vat,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty * 1.15), 0) AS total_with_vat,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty * 0.15), 0) AS vat_amount
      FROM qvm_new_apps.return_items ri2
      JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = ri2.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
      LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
      WHERE ri2.return_id = paged.note_id::bigint
        AND qi2.customer_id = paged.branch_id
        AND paged.note_type = 'RN'
    ) rn_items ON paged.note_type = 'RN';

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_confirmed_orders_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'desc'::text, p_branch_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope integer[];
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);
  v_scope := qvm_new_apps.get_internal_branch_scope(p_user_id);

  WITH base_orders AS (
    SELECT
      co.confirmed_order_id,
      q.quotation_id,
      q.order_number,
      q.created_at,
      co.created_at AS confirmationDate,
      q.plate_number,
      vehicle_info.vin,
      status_info.status AS order_status,
      b.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      b.customer_id AS branch_id,
      b.branch_name,
      q.insurance_company_id,
      ic.name AS insurance_company_name,
      ld_delivery.list_data AS delivery_type,
      ld_order_type.list_data AS order_type,
      u.user_name AS service_advisor,
      q.service_advisor AS service_advisor_id,
      q.shipping_price,
      vehicle_info.main_brand,
      vehicle_info.model,
      vehicle_info.year,
      items_meta.total_value,
      items_meta.item_count,
      co.created_at AS sort_created_at,
      items_meta.total_value AS sort_total_value
    FROM qvm_new_apps.confirmed_orders co
      LEFT JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
      LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
      LEFT JOIN qvm_new_apps.list_data ld_order_type ON ld_order_type.list_data_id = q.order_type
      LEFT JOIN LATERAL (
        SELECT qi.customer_id AS customer_id
        FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC
        LIMIT 1
      ) first_branch ON true
      LEFT JOIN qvm_new_apps.client_branches b ON b.customer_id = first_branch.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = b.list_data_id
      LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = q.insurance_company_id
      LEFT JOIN LATERAL (
        SELECT
          ci2.item_status as item_status_id,
          ldc.list_data AS status,
          CASE
            WHEN p_status IS NULL THEN true
            ELSE EXISTS (
              SELECT 1
              FROM qvm_new_apps.confirmed_items ci_check
              WHERE ci_check.confirmed_order_id = co.confirmed_order_id
                AND ci_check.item_status = p_status::integer
            )
          END as has_filtered_status
        FROM qvm_new_apps.confirmed_items ci2
        LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ci2.item_status
        WHERE ci2.confirmed_order_id = co.confirmed_order_id
        ORDER BY ci2.confirmed_item_id ASC
        LIMIT 1
      ) status_info ON true
      LEFT JOIN LATERAL (
        SELECT
          qi3.vin AS vin,
          ld_brand.list_data AS main_brand,
          qi3.model AS model,
          qi3.year AS year
        FROM qvm_new_apps.quotation_items qi3
        LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
        WHERE qi3.quotation_id = q.quotation_id
        ORDER BY qi3.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
      LEFT JOIN LATERAL (
        SELECT
          COALESCE(
            SUM(
              (qi.total_price_before_vat::numeric) * (1 - COALESCE(qi.discount_percent, 0) / 100)
            ),
            0
          ) AS total_value,
          COUNT(*)::int AS item_count
        FROM qvm_new_apps.confirmed_items ci
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        WHERE ci.confirmed_order_id = co.confirmed_order_id
          AND (
            (v_is_internal AND (v_scope IS NULL OR qi.customer_id = ANY(v_scope)))
            OR (
              v_user_role = 170
              AND EXISTS (
                SELECT 1
                FROM qvm_new_apps.client_branches cb2
                WHERE cb2.customer_id = v_user_branch
                  AND cb2.customer_id = qi.customer_id
              )
            )
            OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
          )
      ) items_meta ON true
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND status_info.has_filtered_status = true
      AND (
        (v_is_internal AND (v_scope IS NULL OR first_branch.customer_id = ANY(v_scope)))
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            WHERE cb.customer_id = v_user_branch
              AND cb.customer_id = first_branch.customer_id
          )
        )
        OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
      )
      AND (NOT v_is_internal OR p_branch_id IS NULL OR first_branch.customer_id = p_branch_id)
      AND items_meta.item_count > 0
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR vehicle_info.vin ILIKE '%' || p_search || '%'
        OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          LEFT JOIN qvm_new_apps.confirmed_items cis ON cis.quotation_item_id = qis.quotation_item_id
          WHERE cis.confirmed_order_id = co.confirmed_order_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
            )
        )
      )
  ),
  paged_orders AS (
    SELECT *
    FROM base_orders
    ORDER BY
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN sort_total_value END ASC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN sort_total_value END DESC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN sort_created_at END ASC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN sort_created_at END DESC,
      sort_created_at DESC
    LIMIT p_limit
    OFFSET p_offset
  ),
  orders_with_details AS (
    SELECT
      jsonb_build_object(
        'confirmed_order_id', po.confirmed_order_id::text,
        'order_number', po.order_number,
        'created_at', po.created_at,
        'confirmationDate', po.confirmationDate,
        'plateNumber', po.plate_number,
        'vin', po.vin,
        'order_status', po.order_status,
        'client_company_id', po.client_company_id,
        'client_company', po.client_company,
        'branch_id', po.branch_id,
        'branch_name', po.branch_name,
        'insurance_company_id', po.insurance_company_id,
        'insurance_company_name', po.insurance_company_name,
        'delivery_type', po.delivery_type,
        'order_type', po.order_type,
        'service_advisor', po.service_advisor,
        'service_advisor_id', po.service_advisor_id,
        'shipping_price', po.shipping_price,
        'main_brand', po.main_brand,
        'model', po.model,
        'year', po.year,
        'total_value', po.total_value,
        'item_count', po.item_count
      ) AS order_data,
      po.sort_created_at,
      po.sort_total_value
    FROM paged_orders po
  ),
  items_cte AS (
    SELECT
      ci.confirmed_order_id,
      jsonb_agg(
        jsonb_build_object(
          'confirmed_item_id', ci.confirmed_item_id::text,
          'quotation_item_id', ci.quotation_item_id,
          'part_number', COALESCE(ci.final_part_number, qi.part_number),
          'final_part_number', ci.final_part_number,
          'part_description', qi.part_description,
          'brand_class', ld_orig_brand.list_data,
          'approved_qty', ci.approved_qty,
          'requested_qty', qi.quantity,
          'final_brand_class', ld_brand.list_data,
          'unit_price', qi.price_before_vat,
          'discounted_price', (qi.total_price_before_vat::numeric) * (1 - COALESCE(qi.discount_percent, 0) / 100),
          'discount_percent', qi.discount_percent,
          'agency_price', qi.agency_price,
          'agency_percentage', null,
          'total_price_before_vat', qi.total_price_before_vat,
          'status', ldc.list_data,
          'status_id', ci.item_status,
          'part_photo', qi.part_photo,
          'item_notes_count', (
            SELECT COUNT(*)::int
            FROM qvm_new_apps.notes n
            WHERE n.note_type = 'quotation_item'
              AND n.type_id = qi.quotation_item_id
          )
        ) ORDER BY ci.confirmed_item_id ASC
      ) FILTER (WHERE ci.confirmed_item_id IS NOT NULL) AS items
    FROM qvm_new_apps.confirmed_items ci
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = COALESCE(ci.final_brand_class, qi.brand_class)
    LEFT JOIN qvm_new_apps.list_data ld_orig_brand ON ld_orig_brand.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ci.item_status
    WHERE ci.confirmed_order_id IN (SELECT confirmed_order_id FROM paged_orders)
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb2
            WHERE cb2.customer_id = v_user_branch
              AND cb2.customer_id = qi.customer_id
          )
        )
        OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
      )
    GROUP BY ci.confirmed_order_id
  ),
  counts AS (
    SELECT count(*)::int AS total_count
    FROM base_orders
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'data', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'order', owd.order_data,
        'items', COALESCE(i.items, '[]'::jsonb)
      ) ORDER BY
        CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN owd.sort_total_value END ASC,
        CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN owd.sort_total_value END DESC,
        CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN owd.sort_created_at END ASC,
        CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN owd.sort_created_at END DESC,
        owd.sort_created_at DESC
      )
      FROM orders_with_details owd
      LEFT JOIN items_cte i ON i.confirmed_order_id = (owd.order_data->>'confirmed_order_id')::bigint
    ), '[]'::jsonb),
    'total_count', (SELECT total_count FROM counts)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;
