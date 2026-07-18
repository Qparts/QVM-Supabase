-- Synced from QVM/test branch applied migration history (version 20260629020737, name: add_part_photo_to_confirmed_orders_dashboard)

CREATE OR REPLACE FUNCTION public.get_confirmed_orders_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'desc'::text)
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
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

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
            v_is_internal
            OR (
              v_user_role = 170
              AND EXISTS (
                SELECT 1
                FROM qvm_new_apps.client_branches cb2
                WHERE cb2.list_data_id = v_company
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
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            WHERE cb.list_data_id = v_company
              AND cb.customer_id = first_branch.customer_id
          )
        )
        OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
      )
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
            WHERE cb2.list_data_id = v_company
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
$function$
;
