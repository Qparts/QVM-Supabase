-- Fix RFQ status logic to consider all items, not just the first one
-- This allows proper filtering by status when RFQs have multiple items
-- Updated with Supabase version including notes functionality

CREATE OR REPLACE FUNCTION public.rfq_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_delivery_type text DEFAULT NULL,
  p_order_type text DEFAULT NULL,
  p_service_advisor uuid DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
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

  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'RFQs fetched successfully',
    'data', COALESCE(jsonb_agg(r.rq ORDER BY (r.rq->>'created_at')::timestamptz DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_id', q.quotation_id,
      'order_number', q.order_number,
      'plate_number', q.plate_number,
      'created_at', q.created_at,
      'service_advisor', u.user_name,
      'service_advisor_id', q.service_advisor,
      'delivery_type', ld_delivery.list_data,
      'order_type', ld_order.list_data,
      'shipping_price', q.shipping_price,
      'shipping_type', q.shipping_type,
      'discount_amount', NULL,
      'branch_id', b.customer_id,
      'branch_name', b.branch_name,
      'client_company_id', b.list_data_id,
      'client_company', ld_company.list_data,
      'rfq_status', status_info.status,
      'vin', vehicle_info.vin,
      'main_brand', vehicle_info.main_brand,
      'model', vehicle_info.model,
      'year', vehicle_info.year,
      'items', items_info.items,
      'notes_count', COALESCE(notes_info.notes_count, 0)
    ) AS rq
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
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
      -- RFQ status logic: Show RFQ if ANY item matches the status filter
      -- Only use quotation_items status - never confirmed_items status
      -- FIXED: Handle status IDs instead of status names
      SELECT 
        qi2.item_status as item_status_id,
        ldr.list_data AS status,
        CASE 
          WHEN p_status IS NULL THEN true
          ELSE EXISTS (
            SELECT 1
            FROM qvm_new_apps.quotation_items qi_check
            WHERE qi_check.quotation_id = q.quotation_id
              AND qi_check.item_status = p_status::integer  -- FIXED: Compare IDs, not names
          ) 
        END as has_filtered_status
      FROM qvm_new_apps.quotation_items qi2
      LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
      WHERE qi2.quotation_id = q.quotation_id
      ORDER BY qi2.quotation_item_id ASC
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
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'quotation_item_id', qi.quotation_item_id,
            'part_number', qi.part_number,
            'part_description', qi.part_description,
            'quantity', qi.quantity,
            'brand_class', ld_bc.list_data,
            'alternative_part_number', qi.alternative_part_number,
            'alternative_brand_class', ld_abc.list_data,
            'part_photo', qi.part_photo,
            'delivery_type', ld_delivery.list_data,
            'order_type', ld_order.list_data,
            'estimated_price', qi.estimated_price,
            'price_before_vat', qi.price_before_vat,
            'discount_percent', qi.discount_percent,
            'agency_price', qi.agency_price,
            'total_price_before_vat', qi.total_price_before_vat,
            'final_part_number', ci.final_part_number,
            'approved_qty', ci.approved_qty,
            'sla',qvi.sla,
            'item_status', ldr2.list_data,
            'item_status_id', qi.item_status,
            'vin', qi.vin,
            'main_brand', ld_brand2.list_data,
            'model', qi.model,
            'year', qi.year,
            'branch_id', qi.customer_id,
            'item_notes_count', (
  SELECT COUNT(*)::int
  FROM qvm_new_apps.notes n
  WHERE n.note_type = 'quotation_items'
    AND n.type_id = qi.quotation_item_id
    AND n.is_internal = FALSE
)
          )
          ORDER BY qi.quotation_item_id
        ),
        '[]'::jsonb
      ) AS items
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ldr2 ON ldr2.list_data_id = qi.item_status
      LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
      LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi.main_brand
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
      WHERE qi.quotation_id = q.quotation_id
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
  WHERE n.note_type = 'quotations'
    AND n.type_id = q.quotation_id
    AND n.is_internal = FALSE
) notes_info ON true
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)    -- FIXED: Compare IDs
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)              -- FIXED: Compare IDs
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND status_info.has_filtered_status = true  -- This ensures RFQ appears if ANY item matches the filter
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
      AND (jsonb_array_length(items_info.items) > 0)
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR vehicle_info.vin ILIKE '%' || p_search || '%'
        OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
            )
        )
      )
  ) r;

  RETURN v_result;
END;
$function$;

-- Revoke and grant permissions to ensure they are properly set
REVOKE EXECUTE ON FUNCTION public.rfq_dashboard(uuid, text, text, text, text, uuid, timestamptz, timestamptz) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.rfq_dashboard(uuid, text, text, text, text, uuid, timestamptz, timestamptz) TO authenticated;