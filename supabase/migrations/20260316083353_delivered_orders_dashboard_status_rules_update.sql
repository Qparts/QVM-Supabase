-- Synced from QVM/test branch applied migration history (version 20260316083353, name: delivered_orders_dashboard_status_rules_update)
-- Create RPC function for Delivered Orders Dashboard

CREATE OR REPLACE FUNCTION public.get_delivered_orders_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_company_id integer DEFAULT NULL,
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamp with time zone DEFAULT NULL,
  p_date_to timestamp with time zone DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_sort_by text DEFAULT 'event_date',
  p_sort_order text DEFAULT 'desc'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
    INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

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
      q.created_at AS order_date,
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
      d.shipping_price,
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
        v_is_internal
        OR (v_user_role = 170 AND cb.list_data_id = v_company)
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
      q.created_at AS order_date,
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
      r.shipping_price,
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
        v_is_internal
        OR (v_user_role = 170 AND cb.list_data_id = v_company)
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
      shipping_price,
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
      shipping_price,
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
            'signedBy', signed_by,
            'signedAt', NULL,
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

REVOKE EXECUTE ON FUNCTION public.get_delivered_orders_dashboard(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone, integer, integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_delivered_orders_dashboard(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone, integer, integer, text, text) TO authenticated;
;
