-- Synced from QVM/test branch applied migration history (version 20260311095857, name: orders_dashboard_rpc_optimized)
-- Create RPC function for Orders Dashboard
-- This function returns confirmed orders with item details based on user permissions

CREATE OR REPLACE FUNCTION public.get_confirmed_orders_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_delivery_type text DEFAULT NULL,
  p_order_type text DEFAULT NULL,
  p_service_advisor uuid DEFAULT NULL,
  p_date_from timestamp with time zone DEFAULT NULL,
  p_date_to timestamp with time zone DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_sort_by text DEFAULT 'created_at',
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

  -- Build the main query (optimize based on sort mode)
  IF p_sort_by = 'total_value' THEN
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
        q.created_at AS sort_created_at,
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
          -- Status logic: Show the status of the first item for display,
          -- but allow filtering by any item status
          -- Only use confirmed_items status - never quotation_items status
          -- FIXED: Handle status IDs instead of status names
          SELECT
            ci2.item_status as item_status_id,
            ldc.list_data AS status,
            CASE
              WHEN p_status IS NULL THEN true
              ELSE EXISTS (
                SELECT 1
                FROM qvm_new_apps.confirmed_items ci_check
                WHERE ci_check.confirmed_order_id = co.confirmed_order_id
                  AND ci_check.item_status = p_status::integer  -- FIXED: Compare IDs, not names
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
        AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)    -- FIXED: Compare IDs
        AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)              -- FIXED: Compare IDs
        AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
        AND status_info.has_filtered_status = true  -- This ensures Order appears if ANY item matches the filter
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
          'items', items_info.items,
          'notes_count', COALESCE(notes_info.notes_count, 0)
        ) AS order_data
      FROM paged_orders po
        LEFT JOIN LATERAL (
          SELECT
            COALESCE(
              jsonb_agg(
                jsonb_build_object(
                  'confirmed_item_id', ci.confirmed_item_id,
                  'partNumber', qi.part_number,
                  'finalPartNumber', ci.final_part_number,
                  'description', qi.part_description,
                  'brand_class', ld_brand.list_data,
                  'finalBrandClass', ld_final_brand.list_data,
                  'requestedQty', qi.quantity,
                  'approvedQty', ci.approved_qty,
                  'price_before_vat', qi.price_before_vat,
                  'discount_percent', qi.discount_percent,
                  'agency_price', qi.agency_price,
                  'total_price_before_vat', qi.total_price_before_vat,
                  'item_status', ld_item_status.list_data,
                  'part_photo', qi.part_photo,
                  'item_notes_count', (
                    SELECT COUNT(*)::int
                    FROM qvm_new_apps.notes n
                    WHERE (
                      (n.note_type = 'confirmed_items' AND n.type_id = ci.confirmed_item_id)
                      OR
                      (n.note_type = 'quotation_items' AND n.type_id = qi.quotation_item_id
                       AND qi.quotation_item_id = ci.quotation_item_id)
                    )
                      AND n.is_internal = FALSE
                  )
                )
                ORDER BY ci.confirmed_item_id
              ),
              '[]'::jsonb
            ) AS items
          FROM qvm_new_apps.confirmed_items ci
          LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
          LEFT JOIN qvm_new_apps.list_data ld_item_status ON ld_item_status.list_data_id = ci.item_status
          LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.brand_class
          LEFT JOIN qvm_new_apps.list_data ld_final_brand ON ld_final_brand.list_data_id = ci.final_brand_class
          WHERE ci.confirmed_order_id = po.confirmed_order_id
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
        ) items_info ON true
        LEFT JOIN LATERAL (
          SELECT COUNT(*)::int AS notes_count
          FROM qvm_new_apps.notes n
          WHERE (
            (n.note_type = 'confirmed_orders' AND n.type_id = po.confirmed_order_id)
            OR
            (n.note_type = 'quotations' AND n.type_id = po.quotation_id)
          )
            AND n.is_internal = FALSE
        ) notes_info ON true
    )
    SELECT jsonb_build_object(
      'status', 'success',
      'message', 'Orders fetched successfully',
      'total_count', (SELECT COUNT(*) FROM base_orders),
      'data', COALESCE(jsonb_agg(order_data), '[]'::jsonb)
    )
    INTO v_result
    FROM orders_with_details;
  ELSE
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
        q.created_at AS sort_created_at
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
          -- Status logic: Show the status of the first item for display,
          -- but allow filtering by any item status
          -- Only use confirmed_items status - never quotation_items status
          -- FIXED: Handle status IDs instead of status names
          SELECT
            ci2.item_status as item_status_id,
            ldc.list_data AS status,
            CASE
              WHEN p_status IS NULL THEN true
              ELSE EXISTS (
                SELECT 1
                FROM qvm_new_apps.confirmed_items ci_check
                WHERE ci_check.confirmed_order_id = co.confirmed_order_id
                  AND ci_check.item_status = p_status::integer  -- FIXED: Compare IDs, not names
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
          SELECT true AS has_items
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
          LIMIT 1
        ) items_meta ON true
      WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
        AND (p_date_to IS NULL OR q.created_at <= p_date_to)
        AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)    -- FIXED: Compare IDs
        AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)              -- FIXED: Compare IDs
        AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
        AND status_info.has_filtered_status = true  -- This ensures Order appears if ANY item matches the filter
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
        AND COALESCE(items_meta.has_items, false) = true
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
          'total_value', totals_info.total_value,
          'items', items_info.items,
          'notes_count', COALESCE(notes_info.notes_count, 0)
        ) AS order_data
      FROM paged_orders po
        LEFT JOIN LATERAL (
          SELECT
            COALESCE(
              SUM(
                (qi.total_price_before_vat::numeric) * (1 - COALESCE(qi.discount_percent, 0) / 100)
              ),
              0
            ) AS total_value
          FROM qvm_new_apps.confirmed_items ci
          LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
          WHERE ci.confirmed_order_id = po.confirmed_order_id
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
        ) totals_info ON true
        LEFT JOIN LATERAL (
          SELECT
            COALESCE(
              jsonb_agg(
                jsonb_build_object(
                  'confirmed_item_id', ci.confirmed_item_id,
                  'partNumber', qi.part_number,
                  'finalPartNumber', ci.final_part_number,
                  'description', qi.part_description,
                  'brand_class', ld_brand.list_data,
                  'finalBrandClass', ld_final_brand.list_data,
                  'requestedQty', qi.quantity,
                  'approvedQty', ci.approved_qty,
                  'price_before_vat', qi.price_before_vat,
                  'discount_percent', qi.discount_percent,
                  'agency_price', qi.agency_price,
                  'total_price_before_vat', qi.total_price_before_vat,
                  'item_status', ld_item_status.list_data,
                  'part_photo', qi.part_photo,
                  'item_notes_count', (
                    SELECT COUNT(*)::int
                    FROM qvm_new_apps.notes n
                    WHERE (
                      (n.note_type = 'confirmed_items' AND n.type_id = ci.confirmed_item_id)
                      OR
                      (n.note_type = 'quotation_items' AND n.type_id = qi.quotation_item_id
                       AND qi.quotation_item_id = ci.quotation_item_id)
                    )
                      AND n.is_internal = FALSE
                  )
                )
                ORDER BY ci.confirmed_item_id
              ),
              '[]'::jsonb
            ) AS items
          FROM qvm_new_apps.confirmed_items ci
          LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
          LEFT JOIN qvm_new_apps.list_data ld_item_status ON ld_item_status.list_data_id = ci.item_status
          LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.brand_class
          LEFT JOIN qvm_new_apps.list_data ld_final_brand ON ld_final_brand.list_data_id = ci.final_brand_class
          WHERE ci.confirmed_order_id = po.confirmed_order_id
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
        ) items_info ON true
        LEFT JOIN LATERAL (
          SELECT COUNT(*)::int AS notes_count
          FROM qvm_new_apps.notes n
          WHERE (
            (n.note_type = 'confirmed_orders' AND n.type_id = po.confirmed_order_id)
            OR
            (n.note_type = 'quotations' AND n.type_id = po.quotation_id)
          )
            AND n.is_internal = FALSE
        ) notes_info ON true
    )
    SELECT jsonb_build_object(
      'status', 'success',
      'message', 'Orders fetched successfully',
      'total_count', (SELECT COUNT(*) FROM base_orders),
      'data', COALESCE(jsonb_agg(order_data), '[]'::jsonb)
    )
    INTO v_result
    FROM orders_with_details;
  END IF;

  RETURN v_result;
END;
$function$;

-- Grant permissions
REVOKE EXECUTE ON FUNCTION public.get_confirmed_orders_dashboard(uuid, text, text, text, text, uuid, timestamp with time zone, timestamp with time zone, integer, integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_confirmed_orders_dashboard(uuid, text, text, text, text, uuid, timestamp with time zone, timestamp with time zone, integer, integer, text, text) TO authenticated;
;
