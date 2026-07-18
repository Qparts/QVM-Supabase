-- QPD-397/398: Returns & Exchanges Dashboard
-- This migration creates tables and RPCs used by the Returns & Exchanges dashboard.

SET search_path TO qvm_new_apps, public;

-- 1) Tables (idempotent)
CREATE TABLE IF NOT EXISTS returned_issues (
  returned_issue_id bigserial PRIMARY KEY,
  confirmed_item_id int NOT NULL REFERENCES qvm_new_apps.confirmed_items(confirmed_item_id) ON DELETE CASCADE,
  confirmed_order_id int NOT NULL REFERENCES qvm_new_apps.confirmed_orders(confirmed_order_id) ON DELETE CASCADE,
  status int NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  return_type int NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  main_supplier int NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  delivery_representative uuid NULL REFERENCES qvm_new_apps.user_data(user_id),
  extraction_source int NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  return_reason int NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  pre_shipping_photo_done boolean DEFAULT false,
  post_photo_review_done boolean DEFAULT false,
  notes text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ri_confirmed_order_id ON qvm_new_apps.returned_issues(confirmed_order_id);
CREATE INDEX IF NOT EXISTS idx_ri_confirmed_item_id ON qvm_new_apps.returned_issues(confirmed_item_id);

CREATE TABLE IF NOT EXISTS returned_issue_attachments (
  attachment_id bigserial PRIMARY KEY,
  returned_issue_id bigint NOT NULL REFERENCES qvm_new_apps.returned_issues(returned_issue_id) ON DELETE CASCADE,
  file_url text NOT NULL,
  file_path text,
  mime_type text,
  file_size int,
  uploaded_by uuid,
  uploaded_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ria_returned_issue_id ON qvm_new_apps.returned_issue_attachments(returned_issue_id);

-- 2) Dashboard RPC (final, corrected version)
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
  -- 1) Compute total with local CTE scope
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
      ld_status.list_data AS status_name,
      ld_rt.list_data AS return_type_name,
      coalesce(ld_sup.list_data, ldv.list_data) AS main_supplier_name,
      udr.user_name AS delivery_representative_name,
      ld_src.list_data AS extraction_source_name,
      ld_reason.list_data AS return_reason_name,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      coalesce(att.urls, '[]'::jsonb) AS attachments
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
    LEFT JOIN LATERAL (
      SELECT coalesce(jsonb_agg(ria.file_url ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ), filtered AS (
    SELECT * FROM issues i
    WHERE (s = '' OR 
           position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.branch_name, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_name IS NOT NULL AND (
           EXISTS (
             SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data = i.return_type_name AND ld.list_data_id = ANY(p_return_type_ids)
           )))
      AND (p_status_ids IS NULL OR i.status_name IS NOT NULL AND (
           EXISTS (
             SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data = i.status_name AND ld.list_data_id = ANY(p_status_ids)
           )))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  )
  SELECT COUNT(*) INTO total FROM filtered;

  -- 2) Compute rows with a fresh local CTE scope
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
      ld_status.list_data AS status_name,
      ld_rt.list_data AS return_type_name,
      coalesce(ld_sup.list_data, ldv.list_data) AS main_supplier_name,
      udr.user_name AS delivery_representative_name,
      ld_src.list_data AS extraction_source_name,
      ld_reason.list_data AS return_reason_name,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      coalesce(att.urls, '[]'::jsonb) AS attachments
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
    LEFT JOIN LATERAL (
      SELECT coalesce(jsonb_agg(ria.file_url ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ), filtered AS (
    SELECT * FROM issues i
    WHERE (s = '' OR 
           position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.branch_name, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_name IS NOT NULL AND (
           EXISTS (
             SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data = i.return_type_name AND ld.list_data_id = ANY(p_return_type_ids)
           )))
      AND (p_status_ids IS NULL OR i.status_name IS NOT NULL AND (
           EXISTS (
             SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data = i.status_name AND ld.list_data_id = ANY(p_status_ids)
           )))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  )
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO rows
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
      delivery_representative_name AS delivery_representative,
      extraction_source_name AS part_number_extraction_source,
      return_reason_name AS return_reason,
      pre_shipping_photo_done,
      post_photo_review_done,
      attachments
    FROM filtered
    ORDER BY 
      CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) = 'asc' THEN order_date END ASC NULLS LAST,
      CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN order_date END DESC NULLS LAST,
      CASE WHEN lower(coalesce(p_sort_by,'')) = 'status' AND lower(coalesce(p_sort_dir,'')) = 'asc' THEN status_name END ASC NULLS LAST,
      CASE WHEN lower(coalesce(p_sort_by,'')) = 'status' AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN status_name END DESC NULLS LAST,
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

-- 3) Filter options RPC (final, corrected version)
CREATE OR REPLACE FUNCTION public.get_return_exchange_filter_options(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ), base AS (
    SELECT 
      ri.returned_issue_id,
      ri.status,
      ri.return_type,
      ci.confirmed_item_id AS ci_confirmed_item_id
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ), branches AS (
    SELECT DISTINCT qi.customer_id AS id, cb.branch_name AS name
    FROM base b
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = b.ci_confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    WHERE qi.customer_id IS NOT NULL
  ), statuses AS (
    SELECT DISTINCT ld.list_data_id AS id, ld.list_data AS name
    FROM base b LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = b.status
    WHERE ld.list_data_id IS NOT NULL
  ), return_types AS (
    SELECT DISTINCT ld.list_data_id AS id, ld.list_data AS name
    FROM base b LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = b.return_type
    WHERE ld.list_data_id IS NOT NULL
  )
  SELECT jsonb_build_object(
    'statuses', coalesce((SELECT jsonb_agg((SELECT x FROM (SELECT id, name) x) ORDER BY name) FROM statuses),'[]'::jsonb),
    'return_types', coalesce((SELECT jsonb_agg((SELECT x FROM (SELECT id, name) x) ORDER BY name) FROM return_types),'[]'::jsonb),
    'branches', coalesce((SELECT jsonb_agg((SELECT x FROM (SELECT id, name) x) ORDER BY name) FROM branches),'[]'::jsonb)
  );
$$;

REVOKE ALL ON FUNCTION public.get_return_exchange_filter_options(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_return_exchange_filter_options(uuid) TO authenticated;
