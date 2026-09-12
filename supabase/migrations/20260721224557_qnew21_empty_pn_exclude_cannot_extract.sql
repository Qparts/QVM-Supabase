-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


CREATE OR REPLACE FUNCTION public.get_empty_part_number_items(p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object('status', 'success', 'message', 'quotation items retreived successfully',
    'total_count', (SELECT COUNT(*)::int FROM qvm_new_apps.quotation_items qi WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '') AND qi.extraction_status IS DISTINCT FROM 'cannot_extract'),
    'data', COALESCE(jsonb_agg(item ORDER BY (item->>'created_at') DESC), '[]'::jsonb)) INTO v_result
  FROM (
    SELECT jsonb_build_object('quotation_item_id', qi.quotation_item_id, 'quotation_id', qi.quotation_id, 'order_number', q.order_number,
      'part_description', qi.part_description, 'quantity', qi.quantity, 'brand_class', ld_bc.list_data, 'brand_class_id', qi.brand_class,
      'alternative_part_number', qi.alternative_part_number, 'alternative_brand_class', ld_abc.list_data, 'main_brand', ld_brand.list_data,
      'model', qi.model, 'year', qi.year, 'vin', qi.vin, 'plate_number', q.plate_number, 'branch_id', qi.customer_id, 'branch_name', cb.branch_name,
      'client_company', ld_company.list_data, 'client_company_id', cb.list_data_id, 'service_advisor', u.user_name, 'service_advisor_id', q.service_advisor,
      'part_number', qi.part_number, 'created_at', qi.created_at, 'empty_since', qi.created_at, 'item_status_id', qi.item_status,
      'item_status', ldr.list_data, 'part_photo', qi.part_photo, 'extraction_status', qi.extraction_status) AS item
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi.item_status
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '') AND qi.extraction_status IS DISTINCT FROM 'cannot_extract'
    ORDER BY qi.created_at DESC LIMIT GREATEST(1, COALESCE(p_limit, 50)) OFFSET GREATEST(0, COALESCE(p_offset, 0))
  ) t;
  RETURN v_result;
END; $function$;

CREATE OR REPLACE FUNCTION public.get_empty_part_number_items(p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object('status', 'success', 'total_count', COUNT(*),
    'data', COALESCE(jsonb_agg(item ORDER BY (item->>'created_at') DESC), '[]'::jsonb)) INTO v_result
  FROM (
    SELECT jsonb_build_object('quotation_item_id', qi.quotation_item_id, 'quotation_id', qi.quotation_id, 'order_number', q.order_number,
      'part_description', qi.part_description, 'quantity', qi.quantity, 'brand_class', ld_bc.list_data, 'brand_class_id', qi.brand_class,
      'alternative_part_number', qi.alternative_part_number, 'alternative_brand_class', ld_abc.list_data, 'main_brand', ld_brand.list_data,
      'model', qi.model, 'year', qi.year, 'vin', qi.vin, 'plate_number', q.plate_number, 'branch_id', qi.customer_id, 'branch_name', cb.branch_name,
      'client_company', ld_company.list_data, 'client_company_id', cb.list_data_id, 'service_advisor', u.user_name, 'service_advisor_id', q.service_advisor,
      'created_at', qi.created_at, 'empty_since', qi.created_at, 'item_status_id', qi.item_status, 'item_status', ldr.list_data,
      'part_photo', qi.part_photo, 'extraction_status', qi.extraction_status) AS item
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi.item_status
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    WHERE (qi.part_number IS NULL OR trim(qi.part_number) = '') AND qi.extraction_status IS DISTINCT FROM 'cannot_extract'
  ) t;
  RETURN v_result;
END; $function$;
notify pgrst, 'reload schema';
