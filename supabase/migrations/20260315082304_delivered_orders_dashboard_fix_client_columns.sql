-- Synced from QVM/test branch applied migration history (version 20260315082304, name: delivered_orders_dashboard_fix_client_columns)
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

  WITH dn_base AS (
    SELECT
      'DN'::text AS note_type,
      d.delivery_id::text AS note_id,
      q.order_number,
      q.created_at AS order_date,
      d.delivery_date AS event_date,
      q.plate_number,
      qi.vin,
      ld_brand.list_data AS brand,
      qi.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      d.signature,
      d.signature_uuid,
      u.user_name AS signed_by,
      d.shipping_price,
      dn_meta.items,
      dn_meta.total_before_vat,
      dn_meta.total_with_vat,
      dn_meta.vat_amount,
      dn_meta.has_pending_item_status,
      dn_meta.has_invoice
    FROM qvm_new_apps.deliveries d
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = d.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.delivery_items di ON di.delivery_id = d.delivery_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = d.signature_uuid
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
          COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty * 0.15), 0) AS vat_amount,
          EXISTS (
            SELECT 1
            FROM qvm_new_apps.delivery_items di3
            JOIN qvm_new_apps.confirmed_items ci3 ON ci3.confirmed_item_id = di3.confirmed_item_id
            WHERE di3.delivery_id = d.delivery_id
              AND ci3.item_status IN (213, 25)
          ) AS has_pending_item_status,
          EXISTS (
            SELECT 1
            FROM qvm_new_apps.delivery_items di4
            WHERE di4.delivery_id = d.delivery_id
              AND di4.invoice_id IS NOT NULL
          ) AS has_invoice
        FROM qvm_new_apps.delivery_items di2
        JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = di2.confirmed_item_id
        JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
        WHERE di2.delivery_id = d.delivery_id
          AND qi2.customer_id = cb.customer_id
      ) dn_meta ON true
    WHERE
      (p_date_from IS NULL OR d.delivery_date >= p_date_from)
      AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
      AND (
        v_is_internal
        OR (v_user_role = 170 AND cb.list_data_id = v_company)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
  ),
  rn_base AS (
    SELECT
      'RN'::text AS note_type,
      r.return_id::text AS note_id,
      q.order_number,
      q.created_at AS order_date,
      r.return_date::timestamp with time zone AS event_date,
      q.plate_number,
      qi.vin,
      ld_brand.list_data AS brand,
      qi.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      r.signature,
      r.signature_uuid,
      u.user_name AS signed_by,
      r.shipping_price,
      rn_meta.items,
      rn_meta.total_before_vat,
      rn_meta.total_with_vat,
      rn_meta.vat_amount,
      rn_meta.has_pending_item_status,
      rn_meta.has_creditnote
    FROM qvm_new_apps.returns r
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = r.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.return_items ri ON ri.return_id = r.return_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = r.signature_uuid
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
          COALESCE(SUM(qi2.price_before_vat * ri2.return_qty * 0.15), 0) AS vat_amount,
          EXISTS (
            SELECT 1
            FROM qvm_new_apps.return_items ri3
            JOIN qvm_new_apps.confirmed_items ci3 ON ci3.confirmed_item_id = ri3.confirmed_item_id
            WHERE ri3.return_id = r.return_id
              AND ci3.item_status IN (214, 215)
          ) AS has_pending_item_status,
          EXISTS (
            SELECT 1
            FROM qvm_new_apps.return_items ri4
            WHERE ri4.return_id = r.return_id
              AND ri4.creditnote_id IS NOT NULL
          ) AS has_creditnote
        FROM qvm_new_apps.return_items ri2
        JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = ri2.confirmed_item_id
        JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
        WHERE ri2.return_id = r.return_id
          AND qi2.customer_id = cb.customer_id
      ) rn_meta ON true
    WHERE
      (p_date_from IS NULL OR r.return_date >= p_date_from)
      AND (p_date_to IS NULL OR r.return_date <= p_date_to)
      AND (
        v_is_internal
        OR (v_user_role = 170 AND cb.list_data_id = v_company)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
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
      items,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_invoice AS has_doc,
      CASE
        WHEN (signature IS NULL OR signature = '') THEN 'DN Sign Pending'
        WHEN NOT has_invoice THEN 'Pending Invoice'
        ELSE 'Invoice Issued'
      END AS status
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
      items,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_creditnote AS has_doc,
      CASE
        WHEN (signature IS NULL OR signature = '') THEN 'RN Sign Pending'
        WHEN NOT has_creditnote THEN 'Pending Credit Note'
        ELSE 'Credit Note Issued'
      END AS status
    FROM rn_base
  ),
  filtered AS (
    SELECT *
    FROM combined
    WHERE
      (p_status IS NULL OR status = p_status)
      AND (
        (signature IS NULL OR signature = '' OR NOT has_doc)
        OR has_pending_item_status = true
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
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'asc' THEN event_date END ASC,
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'desc' THEN event_date END DESC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN total_before_vat END ASC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN total_before_vat END DESC,
      event_date DESC
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
            'totalBeforeVat', total_before_vat,
            'vatAmount', vat_amount,
            'totalWithVat', total_with_vat,
            'shippingFees', COALESCE(shipping_price, 0),
            'signedBy', signed_by,
            'signedAt', NULL,
            'items', items
          )
        ),
        '[]'::jsonb
      )
  )
  INTO v_result
  FROM paged;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_delivered_orders_dashboard(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone, integer, integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_delivered_orders_dashboard(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone, integer, integer, text, text) TO authenticated;
;
