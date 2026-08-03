-- QNEW-86: thread insurance_company_id through quotation creation and surface it (name)
-- wherever quotations/orders are listed. Adding a new parameter changes a function's arity in
-- Postgres (not a REPLACE of the old one), so the old-arity functions are dropped first for
-- create_quotation and get_internal_dashboard (which gains a new filter parameter); the other two
-- dashboards only gain an extra output field, so CREATE OR REPLACE is safe for them.

DROP FUNCTION IF EXISTS public.create_quotation(text, text, integer, integer, uuid, uuid);

CREATE FUNCTION public.create_quotation(
  p_order_number text,
  p_plate_number text,
  p_order_type integer,
  p_delivery_type integer,
  p_service_advisor uuid,
  p_account_manager uuid,
  p_insurance_company_id bigint DEFAULT NULL
)
RETURNS qvm_new_apps.quotations
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_quotation qvm_new_apps.quotations;
BEGIN
  INSERT INTO qvm_new_apps.quotations (
    order_number,
    plate_number,
    order_type,
    delivery_type,
    service_advisor,
    account_manager,
    shipping_type,
    insurance_company_id
  ) VALUES (
    p_order_number::text,
    p_plate_number::text,
    p_order_type,
    p_delivery_type,
    p_service_advisor,
    p_account_manager,
    'item',
    p_insurance_company_id
  )
  RETURNING * INTO v_quotation;

  RETURN v_quotation;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_quotation(text, text, integer, integer, uuid, uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_quotation(text, text, integer, integer, uuid, uuid, bigint) TO service_role;

-- ============================================================================================

DROP FUNCTION IF EXISTS public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], text, text, integer, integer);

CREATE FUNCTION public.get_internal_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_account_managers uuid[] DEFAULT NULL::uuid[], p_clients integer[] DEFAULT NULL::integer[], p_branches integer[] DEFAULT NULL::integer[], p_brands integer[] DEFAULT NULL::integer[], p_statuses integer[] DEFAULT NULL::integer[], p_insurance_company_ids bigint[] DEFAULT NULL::bigint[], p_mode text DEFAULT 'regular'::text, p_view text DEFAULT 'rfqs'::text, p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
  v_rfq_statuses  int[] := ARRAY[17, 216, 217, 218, 235, 236, 237];
  v_order_statuses int[] := ARRAY[19, 21, 22, 23];
BEGIN
  SELECT user_type INTO v_user_type
  FROM qvm_new_apps.user_data WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Access denied: Internal users only',
      'data', '[]'::jsonb
    );
  END IF;

  WITH filtered_quotations AS (
    SELECT DISTINCT
      q.quotation_id,
      q.order_number,
      q.plate_number,
      q.created_at AS rfq_date,
      q.service_advisor,
      q.delivery_type,
      q.order_type,
      q.shipping_price,
      q.shipping_type,
      q.account_manager,
      q.insurance_company_id,
      co.confirmed_order_id,
      co.created_at AS confirmation_date,
      (
        SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC LIMIT 1
      ) AS customer_id,
      (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
      ) AS order_search_matched
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = q.quotation_id
    WHERE
      EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi_any WHERE qi_any.quotation_id = q.quotation_id)
      AND (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_account_managers IS NULL OR q.account_manager = ANY(p_account_managers))
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi2
          LEFT JOIN qvm_new_apps.confirmed_items ci2 ON ci2.quotation_item_id = qi2.quotation_item_id
          WHERE qi2.quotation_id = q.quotation_id
            AND (
              qi2.part_number ILIKE '%' || p_search || '%'
              OR qi2.part_description ILIKE '%' || p_search || '%'
              OR qi2.vin ILIKE '%' || p_search || '%'
              OR ci2.final_part_number ILIKE '%' || p_search || '%'
            )
        )
      )
      AND (
        p_view = 'all'
        OR (p_view = 'rfqs' AND (
          co.confirmed_order_id IS NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_rfq_statuses)
          )
        ))
        OR (p_view = 'orders' AND (
          co.confirmed_order_id IS NOT NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_order_statuses)
          )
        ))
      )
  ),
  filtered_with_branch AS (
    SELECT
      fq.*,
      cb.customer_id AS branch_id,
      cb.branch_name,
      cb.list_data_id AS client_id,
      cb.is_bulk_client,
      ld_client.list_data AS client_name,
      ic.name AS insurance_company_name
    FROM filtered_quotations fq
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fq.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = fq.insurance_company_id
    WHERE
      (p_branches IS NULL OR cb.customer_id = ANY(p_branches))
      AND (p_clients IS NULL OR cb.list_data_id = ANY(p_clients))
      AND (p_insurance_company_ids IS NULL OR fq.insurance_company_id = ANY(p_insurance_company_ids))
      AND (
        (p_mode = 'bulk' AND cb.is_bulk_client = true)
        OR (p_mode = 'regular' AND (cb.is_bulk_client = false OR cb.is_bulk_client IS NULL))
        OR p_mode IS NULL
      )
  ),
  paged_filtered AS (
    SELECT * FROM filtered_with_branch
    ORDER BY rfq_date DESC
    LIMIT GREATEST(p_limit, 1)
    OFFSET GREATEST(p_offset, 0)
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Internal dashboard data fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered_with_branch),
    'data', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'quotation_id', fwb.quotation_id,
            'confirmed_order_id', fwb.confirmed_order_id,
            'order_number', fwb.order_number,
            'plate_number', fwb.plate_number,
            'rfq_date', fwb.rfq_date,
            'confirmation_date', fwb.confirmation_date,
            'branch_id', fwb.branch_id,
            'branch_name', fwb.branch_name,
            'client_id', fwb.client_id,
            'client_name', fwb.client_name,
            'is_bulk_client', fwb.is_bulk_client,
            'insurance_company_id', fwb.insurance_company_id,
            'insurance_company_name', fwb.insurance_company_name,
            'service_advisor', sa.user_name,
            'service_advisor_id', fwb.service_advisor,
            'delivery_type', ld_delivery.list_data,
            'delivery_type_id', fwb.delivery_type,
            'order_type', ld_order.list_data,
            'order_type_id', fwb.order_type,
            'shipping_price', fwb.shipping_price,
            'shipping_type', fwb.shipping_type,
            'account_manager', am.user_name,
            'account_manager_id', fwb.account_manager,
            'account_manager_history', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'account_manager_id', qam.assigned_to,
                  'account_manager_name', am_hist.user_name,
                  'assigned_at', qam.created_at
                )
                ORDER BY qam.created_at DESC
              )
              FROM qvm_new_apps.quotation_account_managers qam
              LEFT JOIN qvm_new_apps.user_data am_hist ON am_hist.user_id = qam.assigned_to
              WHERE qam.quotation_id = fwb.quotation_id
            ),
            'items', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'quotation_item_id', qi.quotation_item_id,
                  'vin', qi.vin,
                  'main_brand', ld_brand.list_data,
                  'main_brand_id', qi.main_brand,
                  'model', qi.model,
                  'year', qi.year,
                  'part_number', qi.part_number,
                  'part_description', qi.part_description,
                  'quantity', qi.quantity,
                  'brand_class', ld_bc.list_data,
                  'brand_class_id', qi.brand_class,
                  'alternative_part_number', qi.alternative_part_number,
                  'alternative_brand_class', ld_abc.list_data,
                  'alternative_brand_class_id', qi.alternative_brand_class,
                  'part_photo', qi.part_photo,
                  'estimated_price', qi.estimated_price,
                  'price_before_vat', qi.price_before_vat,
                  'discount_percent', qi.discount_percent,
                  'agency_price', qi.agency_price,
                  'total_price_before_vat', qi.total_price_before_vat,
                  'item_status', ld_status.list_data,
                  'item_status_id', qi.item_status,
                  'part_category', ld_category.list_data,
                  'part_category_id', qi.part_category,
                  'final_part_number', ci.final_part_number,
                  'approved_qty', ci.approved_qty,
                  'final_brand_class', ld_fbc.list_data,
                  'final_brand_class_id', ci.final_brand_class,
                  'return_type', ld_return.list_data,
                  'return_type_id', ci.return_type,
                  'client_return_reason', ci.client_return_reason,
                  'cancellation_reason', ld_cancel.list_data,
                  'cancellation_reason_id', ci.cancellation_reason,
                  'purchase_cost', qvi.cost,
                  'purchase_supplier', qvi.vendor_id,
                  'item_notes', (
                    SELECT jsonb_agg(
                      jsonb_build_object(
                        'note_id', n.note_id,
                        'note_text', n.note_description,
                        'created_by', n_creator.user_name,
                        'created_at', n.created_at
                      )
                      ORDER BY n.created_at DESC
                    )
                    FROM qvm_new_apps.notes n
                    LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
                    WHERE n.note_type = 'quotation_items'
                      AND n.type_id = qi.quotation_item_id
                      AND n.is_internal = false
                      AND n.deleted_at IS NULL
                  )
                )
                ORDER BY qi.quotation_item_id ASC
              )
              FROM qvm_new_apps.quotation_items qi
              LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
              LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
              LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
              LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
              LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = qi.item_status
              LEFT JOIN qvm_new_apps.list_data ld_category ON ld_category.list_data_id = qi.part_category
              LEFT JOIN qvm_new_apps.list_data ld_fbc ON ld_fbc.list_data_id = ci.final_brand_class
              LEFT JOIN qvm_new_apps.list_data ld_return ON ld_return.list_data_id = ci.return_type
              LEFT JOIN qvm_new_apps.list_data ld_cancel ON ld_cancel.list_data_id = ci.cancellation_reason
              LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
              WHERE qi.quotation_id = fwb.quotation_id
                AND (p_brands IS NULL OR qi.main_brand = ANY(p_brands))
                AND (p_statuses IS NULL OR qi.item_status = ANY(p_statuses))
                AND (
                  p_view = 'all'
                  OR (p_view = 'rfqs'    AND qi.item_status = ANY(v_rfq_statuses))
                  OR (p_view = 'orders'  AND qi.item_status = ANY(v_order_statuses))
                )
                AND (
                  fwb.order_search_matched
                  OR p_search IS NULL
                  OR qi.part_number ILIKE '%' || p_search || '%'
                  OR qi.part_description ILIKE '%' || p_search || '%'
                  OR qi.vin ILIKE '%' || p_search || '%'
                  OR ci.final_part_number ILIKE '%' || p_search || '%'
                )
            ),
            'quotation_notes', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'note_id', n.note_id,
                  'note_text', n.note_description,
                  'created_by', n_creator.user_name,
                  'created_at', n.created_at
                )
                ORDER BY n.created_at DESC
              )
              FROM qvm_new_apps.notes n
              LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
              WHERE n.note_type = 'quotations'
                AND n.type_id = fwb.quotation_id
                AND n.is_internal = false
                AND n.deleted_at IS NULL
            ),
            'payment_account', (
              SELECT ld_payment.list_data
              FROM qvm_new_apps.purchase_orders po
              LEFT JOIN qvm_new_apps.list_data ld_payment ON ld_payment.list_data_id = po.payment_account
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            ),
            'payment_account_id', (
              SELECT po.payment_account
              FROM qvm_new_apps.purchase_orders po
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            )
          )
          ORDER BY fwb.rfq_date DESC
        )
        FROM paged_filtered fwb
        LEFT JOIN qvm_new_apps.user_data sa ON sa.user_id = fwb.service_advisor
        LEFT JOIN qvm_new_apps.user_data am ON am.user_id = fwb.account_manager
        LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = fwb.delivery_type
        LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = fwb.order_type
      ),
      '[]'::jsonb
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$function$
;

REVOKE EXECUTE ON FUNCTION public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], bigint[], text, text, integer, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], bigint[], text, text, integer, integer) TO authenticated;

-- ============================================================================================

CREATE OR REPLACE FUNCTION public.rfq_dashboard_paged(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 10, p_offset integer DEFAULT 0, p_sort_by text DEFAULT NULL::text, p_sort_order text DEFAULT NULL::text, p_branch_id integer DEFAULT NULL::integer)
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

  WITH candidates AS (
    SELECT q.quotation_id, q.created_at
    FROM qvm_new_apps.quotations q
    WHERE
      (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND (
        v_is_internal
        OR (
          v_user_role = 170 AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = q.quotation_id
            WHERE cb.list_data_id = v_company
              AND cb.customer_id = qi.customer_id
            LIMIT 1
          )
        )
        OR (
          v_user_role != 170 AND EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = q.quotation_id
              AND qi2.customer_id = v_user_branch
            LIMIT 1
          )
        )
      )
      AND (
        NOT v_is_internal
        OR p_branch_id IS NULL
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi_branch
          WHERE qi_branch.quotation_id = q.quotation_id
            AND qi_branch.customer_id = p_branch_id
        )
      )
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qis
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
              OR qis.vin ILIKE '%' || p_search || '%'
            )
        )
      )
      AND (
        p_status IS NULL
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi_status
          WHERE qi_status.quotation_id = q.quotation_id
            AND qi_status.item_status = p_status::integer
        )
      )
  ),
  total_cte AS (
    SELECT COUNT(*)::int AS total_count FROM candidates
  ),
  paged AS (
    SELECT quotation_id, created_at
    FROM candidates
    ORDER BY created_at DESC
    LIMIT GREATEST(1, COALESCE(p_limit,10))
    OFFSET GREATEST(0, COALESCE(p_offset,0))
  ),
  quotation_notes AS (
    SELECT n.type_id AS quotation_id, COUNT(*)::int AS notes_count
    FROM qvm_new_apps.notes n
    WHERE n.note_type = 'quotations' AND n.is_internal = FALSE
      AND n.type_id IN (SELECT quotation_id FROM paged)
    GROUP BY n.type_id
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'RFQs fetched successfully',
    'data', COALESCE(jsonb_agg(r.rq ORDER BY r.created_at DESC), '[]'::jsonb),
    'total_count', (SELECT total_count FROM total_cte)
  )
  INTO v_result
  FROM (
    SELECT q.created_at,
      jsonb_build_object(
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
        'insurance_company_id', q.insurance_company_id,
        'insurance_company_name', ic.name,
        'rfq_status', status_info.status,
        'vin', vehicle_info.vin,
        'main_brand', vehicle_info.main_brand,
        'model', vehicle_info.model,
        'year', vehicle_info.year,
        'items', items_info.items,
        'notes_count', COALESCE(qn.notes_count, 0)
      ) AS rq
    FROM paged p
    JOIN qvm_new_apps.quotations q ON q.quotation_id = p.quotation_id
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = q.insurance_company_id
    LEFT JOIN quotation_notes qn ON qn.quotation_id = q.quotation_id

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
        qi2.item_status as item_status_id,
        ldr.list_data AS status,
        CASE
          WHEN p_status IS NULL THEN true
          ELSE EXISTS (
            SELECT 1
            FROM qvm_new_apps.quotation_items qi_check
            WHERE qi_check.quotation_id = q.quotation_id
              AND qi_check.item_status = p_status::integer
          )
        END as has_filtered_status
      FROM qvm_new_apps.quotation_items qi2
      LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
      WHERE qi2.quotation_id = q.quotation_id
      ORDER BY qi2.quotation_item_id ASC
      LIMIT 1
    ) status_info ON true

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
            'delivery_type', ld_delivery2.list_data,
            'order_type', ld_order2.list_data,
            'estimated_price', qi.estimated_price,
            'price_before_vat', qi.price_before_vat,
            'discount_percent', qi.discount_percent,
            'agency_price', qi.agency_price,
            'total_price_before_vat', qi.total_price_before_vat,
            'final_part_number', ci.final_part_number,
            'approved_qty', ci.approved_qty,
            'sla', qvi.sla,
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
      -- Use quotations-level delivery_type/order_type for labels
      LEFT JOIN qvm_new_apps.list_data ld_delivery2 ON ld_delivery2.list_data_id = q.delivery_type
      LEFT JOIN qvm_new_apps.list_data ld_order2 ON ld_order2.list_data_id = q.order_type
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

    WHERE TRUE
  ) r;

  RETURN v_result;
END;
$function$
;

-- ============================================================================================

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
