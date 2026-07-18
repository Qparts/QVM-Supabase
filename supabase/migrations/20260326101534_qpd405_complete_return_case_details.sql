-- Synced from QVM/test branch applied migration history (version 20260326101534, name: qpd405_complete_return_case_details)
SET search_path TO qvm_new_apps, public;

-- 1) Schema adjustments
ALTER TABLE IF EXISTS qvm_new_apps.returned_issues
  ADD COLUMN IF NOT EXISTS delivery_company int NULL REFERENCES qvm_new_apps.list_data(list_data_id);

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE tablename = 'returned_issues' AND indexname = 'uq_return_case_item_order'
  ) THEN
    EXECUTE 'CREATE UNIQUE INDEX uq_return_case_item_order ON qvm_new_apps.returned_issues(confirmed_item_id, confirmed_order_id)';
  END IF;
END $$;

-- 2) Update dashboard RPC to expose IDs for prefill
CREATE OR REPLACE FUNCTION public.get_return_exchange_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_return_type_ids int[] DEFAULT NULL,
  p_status_ids int[] DEFAULT NULL,
  p_branch_ids int[] DEFAULT NULL,
  p_sort_by text DEFAULT 'order_date',
  p_sort_dir text DEFAULT 'desc',
  p_limit int DEFAULT 200,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  rows jsonb;
  total int;
BEGIN
  -- Total
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ), issues AS (
    SELECT 
      ri.returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at AS order_date,
      qi.customer_id,
      cb.branch_name,
      ci.final_part_number,
      ci.final_brand_class,
      ldf.list_data AS final_brand_class_name,
      ci.approved_qty,
      qi.part_description AS part_description,
      ri.status AS status_id,
      ld_status.list_data AS status_name,
      ri.return_type AS return_type_id,
      ld_rt.list_data AS return_type_name,
      COALESCE(ri.main_supplier, qvi.vendor_id) AS main_supplier_id,
      COALESCE(ld_sup.list_data, ldv.list_data) AS main_supplier_name,
      ri.delivery_representative AS delivery_representative_id,
      udr.user_name AS delivery_representative_name,
      ri.extraction_source AS extraction_source_id,
      ld_src.list_data AS extraction_source_name,
      ri.return_reason AS return_reason_id,
      ld_reason.list_data AS return_reason_name,
      ri.delivery_company AS delivery_company_id,
      ldc.list_data AS delivery_company_name,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      COALESCE(att.urls, '[]'::jsonb) AS attachments
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ri.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ri.status
    LEFT JOIN qvm_new_apps.list_data ld_rt ON ld_rt.list_data_id = ri.return_type
    LEFT JOIN qvm_new_apps.list_data ld_sup ON ld_sup.list_data_id = ri.main_supplier
    LEFT JOIN qvm_new_apps.user_data udr ON udr.user_id = ri.delivery_representative
    LEFT JOIN qvm_new_apps.list_data ld_src ON ld_src.list_data_id = ri.extraction_source
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id = ri.return_reason
    LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ri.delivery_company
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(ria.file_url ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ), filtered AS (
    SELECT * FROM issues i
    WHERE (s = '' OR 
           POSITION(lower(s) in lower(COALESCE(i.order_number, ''))) > 0 OR
           POSITION(lower(s) in lower(COALESCE(i.branch_name, ''))) > 0 OR
           POSITION(lower(s) in lower(COALESCE(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_id = ANY(p_return_type_ids))
      AND (p_status_ids IS NULL OR i.status_id = ANY(p_status_ids))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  )
  SELECT COUNT(*) INTO total FROM filtered;

  -- Rows
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ), issues AS (
    SELECT 
      ri.returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at AS order_date,
      qi.customer_id,
      cb.branch_name,
      ci.final_part_number,
      ci.final_brand_class,
      ldf.list_data AS final_brand_class_name,
      ci.approved_qty,
      qi.part_description AS part_description,
      ri.status AS status_id,
      ld_status.list_data AS status_name,
      ri.return_type AS return_type_id,
      ld_rt.list_data AS return_type_name,
      COALESCE(ri.main_supplier, qvi.vendor_id) AS main_supplier_id,
      COALESCE(ld_sup.list_data, ldv.list_data) AS main_supplier_name,
      ri.delivery_representative AS delivery_representative_id,
      udr.user_name AS delivery_representative_name,
      ri.extraction_source AS extraction_source_id,
      ld_src.list_data AS extraction_source_name,
      ri.return_reason AS return_reason_id,
      ld_reason.list_data AS return_reason_name,
      ri.delivery_company AS delivery_company_id,
      ldc.list_data AS delivery_company_name,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      COALESCE(att.urls, '[]'::jsonb) AS attachments
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ri.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ri.status
    LEFT JOIN qvm_new_apps.list_data ld_rt ON ld_rt.list_data_id = ri.return_type
    LEFT JOIN qvm_new_apps.list_data ld_sup ON ld_sup.list_data_id = ri.main_supplier
    LEFT JOIN qvm_new_apps.user_data udr ON udr.user_id = ri.delivery_representative
    LEFT JOIN qvm_new_apps.list_data ld_src ON ld_src.list_data_id = ri.extraction_source
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id = ri.return_reason
    LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ri.delivery_company
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(ria.file_url ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ), filtered AS (
    SELECT * FROM issues i
    WHERE (s = '' OR 
           POSITION(lower(s) in lower(COALESCE(i.order_number, ''))) > 0 OR
           POSITION(lower(s) in lower(COALESCE(i.branch_name, ''))) > 0 OR
           POSITION(lower(s) in lower(COALESCE(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_id = ANY(p_return_type_ids))
      AND (p_status_ids IS NULL OR i.status_id = ANY(p_status_ids))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO rows
  FROM (
    SELECT 
      returned_issue_id,
      confirmed_item_id,
      confirmed_order_id,
      order_number,
      order_date,
      branch_name,
      status_name AS status,
      part_description,
      final_part_number,
      final_brand_class_name AS final_brand_class,
      approved_qty,
      return_type_name AS return_type,
      main_supplier_name AS main_supplier,
      main_supplier_id,
      delivery_representative_name AS delivery_representative,
      delivery_representative_id,
      extraction_source_name AS part_number_extraction_source,
      extraction_source_id,
      return_reason_name AS return_reason,
      return_reason_id,
      delivery_company_name,
      delivery_company_id,
      pre_shipping_photo_done,
      post_photo_review_done,
      attachments
    FROM filtered
    ORDER BY 
      CASE WHEN lower(COALESCE(p_sort_by,'')) = 'order_date' AND lower(COALESCE(p_sort_dir,'')) = 'asc' THEN order_date END ASC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort_by,'')) = 'order_date' AND lower(COALESCE(p_sort_dir,'')) <> 'asc' THEN order_date END DESC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort_by,'')) = 'status' AND lower(COALESCE(p_sort_dir,'')) = 'asc' THEN status_name END ASC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort_by,'')) = 'status' AND lower(COALESCE(p_sort_dir,'')) <> 'asc' THEN status_name END DESC NULLS LAST,
      order_number DESC,
      confirmed_item_id ASC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'status','success',
    'message','OK',
    'total', total,
    'rows', rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_return_exchange_dashboard(uuid, text, int[], int[], int[], text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_return_exchange_dashboard(uuid, text, int[], int[], int[], text, text, int, int) TO authenticated;

-- 3) Upsert return case details
CREATE OR REPLACE FUNCTION public.upsert_return_case(
  p_user_id uuid,
  p_confirmed_item_id int,
  p_confirmed_order_id int,
  p_main_supplier_id int,
  p_delivery_representative uuid,
  p_extraction_source_id int,
  p_return_reason_id int,
  p_pre_shipping boolean,
  p_post_photo boolean,
  p_delivery_company_id int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id AND ud.user_type = 185) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  INSERT INTO qvm_new_apps.returned_issues (
    confirmed_item_id,
    confirmed_order_id,
    status,
    return_type,
    main_supplier,
    delivery_representative,
    extraction_source,
    return_reason,
    pre_shipping_photo_done,
    post_photo_review_done,
    delivery_company,
    created_by,
    updated_by
  ) VALUES (
    p_confirmed_item_id,
    p_confirmed_order_id,
    NULL,
    NULL,
    p_main_supplier_id,
    p_delivery_representative,
    p_extraction_source_id,
    p_return_reason_id,
    p_pre_shipping,
    p_post_photo,
    p_delivery_company_id,
    p_user_id,
    p_user_id
  )
  ON CONFLICT (confirmed_item_id, confirmed_order_id)
  DO UPDATE SET
    main_supplier = EXCLUDED.main_supplier,
    delivery_representative = EXCLUDED.delivery_representative,
    extraction_source = EXCLUDED.extraction_source,
    return_reason = EXCLUDED.return_reason,
    pre_shipping_photo_done = EXCLUDED.pre_shipping_photo_done,
    post_photo_review_done = EXCLUDED.post_photo_review_done,
    delivery_company = EXCLUDED.delivery_company,
    updated_by = EXCLUDED.updated_by,
    updated_at = now()
  RETURNING returned_issue_id INTO v_id;

  RETURN jsonb_build_object('status','success','returned_issue_id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_return_case(uuid, int, int, int, uuid, int, int, boolean, boolean, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_return_case(uuid, int, int, int, uuid, int, int, boolean, boolean, int) TO authenticated;

-- 4) Add attachments to a return case
CREATE OR REPLACE FUNCTION public.add_return_issue_attachment(
  p_user_id uuid,
  p_returned_issue_id bigint,
  p_file_url text,
  p_file_path text DEFAULT NULL,
  p_mime_type text DEFAULT NULL,
  p_file_size int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.returned_issues ri JOIN qvm_new_apps.user_data ud ON ud.user_id = p_user_id WHERE ri.returned_issue_id = p_returned_issue_id AND ud.user_type = 185) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  INSERT INTO qvm_new_apps.returned_issue_attachments (
    returned_issue_id,
    file_url,
    file_path,
    mime_type,
    file_size,
    uploaded_by
  ) VALUES (
    p_returned_issue_id,
    p_file_url,
    p_file_path,
    p_mime_type,
    p_file_size,
    p_user_id
  ) RETURNING attachment_id INTO v_id;

  RETURN jsonb_build_object('status','success','attachment_id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.add_return_issue_attachment(uuid, bigint, text, text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_return_issue_attachment(uuid, bigint, text, text, text, int) TO authenticated;

-- 5) List delivery representatives (internal users)
CREATE OR REPLACE FUNCTION public.list_delivery_representatives()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT coalesce(jsonb_agg((SELECT x FROM (SELECT ud.user_id, ud.user_name) x) ORDER BY ud.user_name), '[]'::jsonb)
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_type = 185 AND ud.user_name IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.list_delivery_representatives() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_delivery_representatives() TO authenticated;;
