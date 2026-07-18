-- Part number extraction feature: logs, tender dashboard, and empty part number endpoints

BEGIN;

-- 1. Log table for part number extraction events
CREATE TABLE IF NOT EXISTS qvm_new_apps.part_number_extraction_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL,
  quotation_item_id integer NOT NULL REFERENCES qvm_new_apps.quotation_items(quotation_item_id),
  part_number text NOT NULL,
  empty_since timestamptz,
  empty_until timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index for fast lookup by quotation_item_id
CREATE INDEX IF NOT EXISTS idx_part_number_extraction_logs_quotation_item_id
  ON qvm_new_apps.part_number_extraction_logs (quotation_item_id);

-- Index for fast lookup by user
CREATE INDEX IF NOT EXISTS idx_part_number_extraction_logs_user_id
  ON qvm_new_apps.part_number_extraction_logs (user_id);

-- 2. Function: return all quotation_items that have no part_number inserted
CREATE OR REPLACE FUNCTION public.get_empty_part_number_items(
  p_user_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'quotation items retreived successfully',
    'total_count', (SELECT COUNT(*)::int FROM qvm_new_apps.quotation_items qi WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '')),
    'data', COALESCE(jsonb_agg(item ORDER BY (item->>'created_at') DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_item_id', qi.quotation_item_id,
      'quotation_id', qi.quotation_id,
      'order_number', q.order_number,
      'part_description', qi.part_description,
      'quantity', qi.quantity,
      'brand_class', ld_bc.list_data,
      'brand_class_id', qi.brand_class,
      'alternative_part_number', qi.alternative_part_number,
      'alternative_brand_class', ld_abc.list_data,
      'main_brand', ld_brand.list_data,
      'model', qi.model,
      'year', qi.year,
      'vin', qi.vin,
      'plate_number', q.plate_number,
      'branch_id', qi.customer_id,
      'branch_name', cb.branch_name,
      'client_company', ld_company.list_data,
      'client_company_id', cb.list_data_id,
      'service_advisor', u.user_name,
      'service_advisor_id', q.service_advisor,
      'part_number', qi.part_number,
      'created_at', qi.created_at,
      'empty_since', qi.created_at,
      'item_status_id', qi.item_status,
      'item_status', ldr.list_data,
      'part_photo', qi.part_photo
    ) AS item
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi.item_status
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '')
    ORDER BY qi.created_at DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 50))
    OFFSET GREATEST(0, COALESCE(p_offset, 0))
  ) t;

  RETURN v_result;
END;
$$;

-- 3. Function: return tender dashboard grouped by quotation (items with empty part number)
CREATE OR REPLACE FUNCTION public.get_tender_requests(
  p_user_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  WITH eligible_items AS (
    SELECT
      qi.quotation_item_id,
      qi.quotation_id,
      qi.part_description,
      qi.quantity,
      qi.brand_class,
      qi.alternative_part_number,
      qi.alternative_brand_class,
      qi.main_brand,
      qi.model,
      qi.year,
      qi.vin,
      qi.part_photo,
      qi.created_at,
      ld_bc.list_data AS brand_class_name,
      ld_abc.list_data AS alternative_brand_class_name,
      ld_brand.list_data AS main_brand_name,
      ldr.list_data AS item_status_name,
      ROW_NUMBER() OVER (PARTITION BY qi.quotation_id ORDER BY qi.quotation_item_id) AS item_position
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi.item_status
    WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '')
  ),
  quotation_stats AS (
    SELECT
      quotation_id,
      COUNT(*)::int AS total_items,
      COUNT(*)::int AS remaining_items
    FROM eligible_items
    GROUP BY quotation_id
  ),
  paged_quotations AS (
    SELECT DISTINCT quotation_id
    FROM eligible_items
    ORDER BY quotation_id DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 50))
    OFFSET GREATEST(0, COALESCE(p_offset, 0))
  ),
  total_cte AS (
    SELECT COUNT(DISTINCT quotation_id)::int AS total_count FROM eligible_items
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'total_count', (SELECT total_count FROM total_cte),
    'data', COALESCE(jsonb_agg(r.rq ORDER BY r.quotation_id DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT q.quotation_id,
      jsonb_build_object(
        'quotation_id', q.quotation_id,
        'order_number', q.order_number,
        'plate_number', q.plate_number,
        'created_at', q.created_at,
        'service_advisor', u.user_name,
        'service_advisor_id', q.service_advisor,
        'delivery_type', ld_delivery.list_data,
        'order_type', ld_order.list_data,
        'branch_id', b.customer_id,
        'branch_name', b.branch_name,
        'client_company', ld_company.list_data,
        'client_company_id', b.list_data_id,
        'vin', vehicle_info.vin,
        'main_brand', vehicle_info.main_brand_name,
        'model', vehicle_info.model,
        'year', vehicle_info.year,
        'total_items', qs.total_items,
        'remaining_items', qs.remaining_items,
        'done_items', qs.total_items - qs.remaining_items,
        'items', COALESCE(items_info.items, '[]'::jsonb)
      ) AS rq
    FROM paged_quotations pq
    JOIN qvm_new_apps.quotations q ON q.quotation_id = pq.quotation_id
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
    LEFT JOIN quotation_stats qs ON qs.quotation_id = pq.quotation_id

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
        ld_brand.list_data AS main_brand_name,
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
            'quotation_item_id', ei.quotation_item_id,
            'item_position', ei.item_position,
            'part_number', NULL,
            'part_description', ei.part_description,
            'quantity', ei.quantity,
            'brand_class', ei.brand_class_name,
            'brand_class_id', ei.brand_class,
            'alternative_part_number', ei.alternative_part_number,
            'alternative_brand_class', ei.alternative_brand_class_name,
            'main_brand', ei.main_brand_name,
            'model', ei.model,
            'year', ei.year,
            'vin', ei.vin,
            'part_photo', ei.part_photo,
            'created_at', ei.created_at,
            'item_status', ei.item_status_name
          )
          ORDER BY ei.item_position
        ),
        '[]'::jsonb
      ) AS items
      FROM eligible_items ei
      WHERE ei.quotation_id = q.quotation_id
    ) items_info ON true
  ) r;

  RETURN v_result;
END;
$$;

-- 4. Function: set a part_number on a quotation_item and log the extraction
DROP FUNCTION IF EXISTS public.set_part_number(integer, text);

CREATE OR REPLACE FUNCTION public.set_part_number(
  p_quotation_item_id integer,
  p_part_number text,
  p_file_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_quotation_id integer;
  v_created_at timestamptz;
  v_log_id bigint;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_quotation_item_id IS NULL OR p_part_number IS NULL OR trim(p_part_number) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'quotation_item_id and a non-empty part_number are required');
  END IF;

  SELECT qi.quotation_id, qi.created_at
  INTO v_quotation_id, v_created_at
  FROM qvm_new_apps.quotation_items qi
  WHERE qi.quotation_item_id = p_quotation_item_id;

  IF v_quotation_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Quotation item not found');
  END IF;

  UPDATE qvm_new_apps.quotation_items
  SET part_number = trim(p_part_number),
      item_status = CASE WHEN item_status = 236 THEN 235 ELSE item_status END,
      updated_at = now()
  WHERE quotation_item_id = p_quotation_item_id;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT p_quotation_item_id, 235, v_user_id, now()
  WHERE EXISTS (
    SELECT 1 FROM qvm_new_apps.quotation_items qi
    WHERE qi.quotation_item_id = p_quotation_item_id AND qi.item_status = 235
  )
  ON CONFLICT DO NOTHING;

  INSERT INTO qvm_new_apps.part_number_extraction_logs (
    user_id,
    quotation_item_id,
    part_number,
    empty_since,
    empty_until,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    p_quotation_item_id,
    trim(p_part_number),
    v_created_at,
    now(),
    now(),
    now()
  )
  RETURNING id INTO v_log_id;

  IF p_file_path IS NOT NULL AND trim(p_file_path) <> '' THEN
    INSERT INTO qvm_new_apps.files (
      module_id,
      module_type,
      user_id,
      file_path,
      field_id
    ) VALUES (
      v_log_id,
      'part_number_extraction_logs',
      v_user_id,
      trim(p_file_path),
      'attachment'
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'quotation items part number updated to ' || trim(p_part_number),
    'data', NULL
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_empty_part_number_items(uuid, int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_empty_part_number_items(uuid, int, int) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.get_tender_requests(uuid, int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_tender_requests(uuid, int, int) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.set_part_number(integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_part_number(integer, text, text) TO authenticated;

COMMIT;
