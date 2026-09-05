-- Returns & Exchanges: one table instead of three tabs.
--
-- The page showed returned_issues cases in the main table and the pending cancellation/return
-- requests behind two separate tabs, each on its own RPC. Merging them client-side would have
-- broken paging (two paginated sources cannot share a page number or a total), so the union
-- happens here and the page stays a single server-paginated table.
--
-- Rows carry record_type ('case' | 'cancellation_request' | 'return_request') and a row_key that is
-- unique across both sources, since a returned_issue_id and a confirmed_item_id can collide.
--
-- The existing filters keep working across the union: the status filter is list 3 (item_status),
-- which already contains 24 "Cancellation Request" and 28 "Return Request", so pending rows carry
-- their item_status as the status and are filterable by it like any other. The return-type filter
-- only matches cases, since a pending request has no disposition until it is approved.
--
-- Attachments differ between the sources — cases store a resolved file_url, request notes store a
-- storage path — so both are normalised to [{url, path}] and the client resolves whichever is set.
-- Building the public URL here would mean hardcoding a project ref, which differs per branch.
--
-- Signature is unchanged on purpose: adding a parameter with a DEFAULT would create a second
-- overload and make the frontend's named-argument call ambiguous.

CREATE OR REPLACE FUNCTION public.get_return_exchange_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL::text,
  p_return_type_ids integer[] DEFAULT NULL::integer[],
  p_status_ids integer[] DEFAULT NULL::integer[],
  p_branch_ids integer[] DEFAULT NULL::integer[],
  p_sort_by text DEFAULT 'order_date'::text,
  p_sort_dir text DEFAULT 'desc'::text,
  p_limit integer DEFAULT 200,
  p_offset integer DEFAULT 0
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  rows jsonb;
  total int;
BEGIN
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  cases AS (
    SELECT
      'case:' || ri.returned_issue_id            AS row_key,
      'case'::text                               AS record_type,
      ri.returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at                               AS order_date,
      qi.customer_id,
      cb.branch_name,
      ld_client.list_data                        AS client_name,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data                              AS final_brand_class,
      ci.approved_qty,
      NULL::int                                  AS requested_qty,
      ri.status                                  AS status_id,
      ld_status.list_data                        AS status,
      ri.return_type                             AS return_type_id,
      ld_rt.list_data                            AS return_type,
      COALESCE(ri.main_supplier, qvi.vendor_id)  AS main_supplier_id,
      coalesce(ld_sup.list_data, ldv.list_data)  AS main_supplier,
      udr.user_name                              AS delivery_representative,
      ld_src.list_data                           AS part_number_extraction_source,
      ld_reason.list_data                        AS return_reason,
      NULL::text                                 AS note_text,
      NULL::text                                 AS requested_by_name,
      NULL::timestamptz                          AS requested_at,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      coalesce(att.urls, '[]'::jsonb)            AS attachments
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ri.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
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
      SELECT coalesce(jsonb_agg(jsonb_build_object('url', ria.file_url, 'path', NULL)
                                ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
  ),
  requests AS (
    SELECT
      'req:' || ci.confirmed_item_id             AS row_key,
      CASE ci.item_status WHEN 24 THEN 'cancellation_request' ELSE 'return_request' END AS record_type,
      NULL::bigint                               AS returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at                               AS order_date,
      qi.customer_id,
      cb.branch_name,
      ld_client.list_data                        AS client_name,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data                              AS final_brand_class,
      ci.approved_qty,
      ci.requested_return_qty                    AS requested_qty,
      ci.item_status                             AS status_id,
      ld_status.list_data                        AS status,
      NULL::int                                  AS return_type_id,
      NULL::text                                 AS return_type,
      qvi.vendor_id                              AS main_supplier_id,
      ldv.list_data                              AS main_supplier,
      NULL::text                                 AS delivery_representative,
      NULL::text                                 AS part_number_extraction_source,
      ld_reason.list_data                        AS return_reason,
      nt.note_text,
      (SELECT ud2.user_name FROM qvm_new_apps.user_data ud2 WHERE ud2.user_id = (
         SELECT sl.status_changed_by FROM qvm_new_apps.status_logs sl
         WHERE sl.confirmed_item_id = ci.confirmed_item_id AND sl.item_status = ci.item_status
         ORDER BY sl.created_at DESC LIMIT 1
       ))                                        AS requested_by_name,
      ci.updated_at                              AS requested_at,
      NULL::boolean                              AS pre_shipping_photo_done,
      NULL::boolean                              AS post_photo_review_done,
      coalesce(natt.files, '[]'::jsonb)          AS attachments
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id =
      (CASE WHEN ci.item_status = 24 THEN ci.cancellation_reason ELSE ci.client_return_reason END)
    -- The request's own note, not merely the newest note on the item.
    LEFT JOIN LATERAL (
      SELECT n.note_id, n.note_description AS note_text
      FROM qvm_new_apps.notes n
      WHERE n.note_type = 'confirmed_items'
        AND n.type_id = ci.confirmed_item_id
        AND (ci.pending_request_note_id IS NULL OR n.note_id = ci.pending_request_note_id)
      ORDER BY n.created_at DESC
      LIMIT 1
    ) nt ON true
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object('url', NULL, 'path', f.file_path)) AS files
      FROM qvm_new_apps.files f
      WHERE f.module_type = 'notes' AND f.module_id = nt.note_id
    ) natt ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
      AND ci.item_status IN (24, 28)
  ),
  unioned AS (
    SELECT * FROM cases
    UNION ALL
    SELECT * FROM requests
  ),
  filtered AS (
    SELECT * FROM unioned i
    WHERE (s = '' OR
           position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.branch_name, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_id = ANY(p_return_type_ids))
      AND (p_status_ids IS NULL OR i.status_id = ANY(p_status_ids))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  ),
  -- Numbered over the final ordering, so the page and the total come from one pass.
  ordered AS (
    SELECT f.*, row_number() OVER (
      ORDER BY
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) = 'asc'  THEN f.order_date END ASC  NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN f.order_date END DESC NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'status'     AND lower(coalesce(p_sort_dir,'')) = 'asc'  THEN f.status     END ASC  NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'status'     AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN f.status     END DESC NULLS LAST,
        f.order_number DESC,
        f.confirmed_item_id ASC
    ) AS rn
    FROM filtered f
  )
  SELECT
    count(*)::int,
    coalesce(
      jsonb_agg(to_jsonb(o) - 'rn' ORDER BY o.rn)
        FILTER (WHERE o.rn > p_offset AND o.rn <= p_offset + p_limit),
      '[]'::jsonb)
  INTO total, rows
  FROM ordered o;

  RETURN jsonb_build_object(
    'status','success',
    'message','OK',
    'total', total,
    'rows', rows
  );
END;
$function$;
