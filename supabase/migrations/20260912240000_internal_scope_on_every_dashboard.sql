-- An internal account sees the branches it was given, on every screen.
--
-- get_internal_branch_scope now knows about company and workshop scopes, but a second family of
-- dashboards never asks it anything: they build their own user_ctx, and the first line of the
-- filter is `WHERE uc.is_internal` — every internal user, every branch, full stop. That is why a
-- company user could still read purchase orders, returns and order summaries belonging to other
-- companies after their scope was fixed everywhere else.
--
-- The internal branch of the filter now reads the same way everywhere: internal AND within scope.
-- NULL scope still means unrestricted, so a Qparts Admin is untouched, and a client user's own
-- clauses are left exactly as they were.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_result jsonb;
BEGIN
  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  po_agg AS (
    SELECT pi.purchase_order_id,
      count(*)                                                                        AS item_count,
      count(*) FILTER (WHERE pi.receipt_status = 'received')                          AS received_count,
      count(*) FILTER (WHERE pi.receipt_status = 'lower_qty')                         AS lower_qty_count,
      count(*) FILTER (WHERE pi.receipt_status = 'wrong_part')                        AS wrong_part_count,
      count(*) FILTER (WHERE pi.receipt_status IS NULL OR pi.receipt_status = 'not_received') AS not_received_count,
      -- Returned to the vendor, or returned by the client and kept in stock (disposition 134,
      -- which never touches the purchase line). Either way the item came back.
      count(*) FILTER (WHERE COALESCE(pi.returned_qty, 0) > 0
                          OR COALESCE(ci.returned_qty, 0) > 0)                        AS returned_count,
      sum(GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0))   AS total_approved_qty,
      sum(COALESCE(pi.returned_qty, 0))                                               AS total_returned_qty,
      sum(COALESCE(qvi.cost, 0) * GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)) AS total_value
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE pi.purchase_order_id IS NOT NULL
    GROUP BY pi.purchase_order_id
  ),
  vcn_by_po AS (
    SELECT vcn.purchase_order_id, count(*) AS vcn_count
    FROM qvm_new_apps.vendor_creditnotes vcn GROUP BY vcn.purchase_order_id
  ),
  base AS (
    SELECT
      po.purchase_order_id,
      ('PO-' || po.purchase_order_id) AS po_number,
      q.order_number,
      co.created_at AS confirmation_date,
      po.created_at AS po_created_at,
      vnd.vendor_name,
      po.vendor_id,
      cb.branch_name,
      first_branch.customer_id,
      -- Falls back to uploaded_by: POs raised through upsert_purchase_order_items record the user
      -- there, and older rows predate the created_by trigger.
      COALESCE(ucb.user_name, uup.user_name) AS created_by_name,
      COALESCE(po.created_by, po.uploaded_by) AS created_by,
      a.item_count, a.received_count, a.lower_qty_count, a.wrong_part_count, a.not_received_count,
      a.returned_count, a.total_approved_qty, a.total_returned_qty, a.total_value,
      po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url,
      COALESCE(v.vcn_count, 0) AS vcn_count
    FROM qvm_new_apps.purchase_orders po
    JOIN po_agg a ON a.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
    LEFT JOIN qvm_new_apps.user_data ucb ON ucb.user_id = po.created_by
    LEFT JOIN qvm_new_apps.user_data uup ON uup.user_id = po.uploaded_by
    LEFT JOIN vcn_by_po v ON v.purchase_order_id = po.purchase_order_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_branch.customer_id
  ),
  filtered AS (
    SELECT * FROM base b
    WHERE (p_search IS NULL OR p_search = '' OR b.order_number ILIKE '%'||p_search||'%' OR b.vendor_name ILIKE '%'||p_search||'%' OR b.po_number ILIKE '%'||p_search||'%'
           OR b.created_by_name ILIKE '%'||p_search||'%')
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR b.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR b.vendor_id = ANY(v_supplier_ids))
      AND (NOT p_missing_pi OR (
        (coalesce(nullif(trim(b.vendor_invoice_url), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.vendor_invoice_number), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.zoho_bill_url), ''), null) IS NULL)
      ))
      AND (NOT p_missing_rn OR b.vcn_count = 0)
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'total', (SELECT count(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.purchase_order_id DESC) FROM (
        SELECT purchase_order_id, po_number, order_number, confirmation_date, po_created_at,
               vendor_name, branch_name, created_by, created_by_name,
               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               returned_count, total_approved_qty, total_returned_qty, total_value
        FROM filtered ORDER BY purchase_order_id DESC LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false, p_account_manager uuid DEFAULT NULL::uuid, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 200, p_offset integer DEFAULT 0, p_purchase_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_delivered_ids int[];
  result jsonb;
BEGIN
  SELECT COALESCE(array_agg(list_data_id), ARRAY[]::int[]) INTO v_delivered_ids
  FROM qvm_new_apps.list_data WHERE lower(list_data) LIKE 'deliver%';

  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, ud.user_type AS user_type, (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  latest_po_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      po.purchase_order_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url,
      po.uploaded_by AS invoice_uploaded_by
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    -- Asked about one purchase order, answer about that one. Every invoice upload opens a purchase
    -- order of its own to hold its document, so an item that has been invoiced has a newer one than
    -- the order it was actually bought on — and picking the newest made it vanish from the purchase
    -- order the buyer was looking at.
    WHERE p_purchase_order_id IS NULL OR pi.purchase_order_id = p_purchase_order_id
    ORDER BY pi.confirmed_item_id, po.created_at DESC
  ),
  latest_vcn_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      vcn.vendor_creditnote_url,
      vcn.uploaded_by AS creditnote_uploaded_by
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    ORDER BY pi.confirmed_item_id, vcn.created_at DESC
  ),
  attachments_per_item AS (
    SELECT pi.confirmed_item_id, COALESCE(array_agg(pia.file_url ORDER BY pia.uploaded_at DESC), ARRAY[]::text[]) AS invoice_attachments
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.purchase_invoice_attachments pia ON pia.purchase_order_id = po.purchase_order_id
    GROUP BY pi.confirmed_item_id
  ),
  vcn_attachments_per_item AS (
    SELECT pi.confirmed_item_id, COALESCE(array_agg(vcn.vendor_creditnote_url ORDER BY vcn.created_at DESC), ARRAY[]::text[]) AS vendor_creditnote_attachments
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    GROUP BY pi.confirmed_item_id
  ),
  latest_delivered AS (
    SELECT confirmed_item_id, status_changed_by
    FROM (
      SELECT sl.confirmed_item_id, sl.status_changed_by,
             row_number() OVER (PARTITION BY sl.confirmed_item_id ORDER BY sl.created_at DESC) AS rn
      FROM qvm_new_apps.status_logs sl
      WHERE sl.item_status = ANY (v_delivered_ids)
    ) d WHERE rn = 1
  ),
  base AS (
    SELECT
      ci.confirmed_item_id,
      co.confirmed_order_id,
      ci.quotation_item_id,
      q.order_number,
      q.created_at AS rfq_date,
      co.created_at AS confirmation_date,
      q.account_manager,
      qi.customer_id,
      cb.branch_name,
      qi.model,
      ldb.list_data AS main_brand,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data AS final_brand_class,
      ci.approved_qty,
      qvi.cost AS purchase_cost,
      qvi.vendor_id,
      vnd.vendor_name,
      lpo.purchase_order_id,
      lpo.vendor_invoice_url,
      lpo.vendor_invoice_number,
      lpo.zoho_bill_url,
      lpo.invoice_uploaded_by,
      lvcn.creditnote_uploaded_by,
      lvcn.vendor_creditnote_url,
      ao.invoice_attachments,
      vao.vendor_creditnote_attachments,
      ld.status_changed_by AS delivered_by,
      uc.is_internal AS is_internal_user,
      pit.receipt_status,
      pit.received_qty
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN user_ctx uc ON true
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = qvi.vendor_id
    LEFT JOIN latest_po_by_item lpo ON lpo.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN latest_vcn_by_item lvcn ON lvcn.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN attachments_per_item ao ON ao.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN vcn_attachments_per_item vao ON vao.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN latest_delivered ld ON ld.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN qvm_new_apps.purchase_items pit ON pit.confirmed_item_id = ci.confirmed_item_id AND pit.purchase_order_id = lpo.purchase_order_id
  ),
  filtered AS (
    SELECT * FROM base i
    WHERE (s = '' OR position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (
        CASE
          WHEN p_missing_pi AND p_missing_rn THEN
            (
              (coalesce(nullif(trim(i.vendor_invoice_url), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.vendor_invoice_number), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.zoho_bill_url), ''), null) IS NULL)
            )
            OR
            (
              i.vendor_creditnote_url IS NULL
            )
          ELSE
            (NOT p_missing_pi OR (
              (coalesce(nullif(trim(i.vendor_invoice_url), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.vendor_invoice_number), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.zoho_bill_url), ''), null) IS NULL)
            ))
            AND (NOT p_missing_rn OR i.vendor_creditnote_url IS NULL)
        END
      )
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
      AND (p_is_manager OR i.is_internal_user OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
      AND (p_purchase_order_id IS NULL OR i.purchase_order_id = p_purchase_order_id)
  )
  SELECT jsonb_build_object(
    'status','success',
    'message','OK',
    'total', (SELECT COUNT(*) FROM filtered),
    'orders_total', (SELECT COUNT(DISTINCT confirmed_order_id) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t)) FROM (
        SELECT
          confirmed_item_id,
          confirmed_order_id,
          quotation_item_id,
          order_number,
          rfq_date,
          confirmation_date,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = delivered_by) AS delivered_by_name,
          purchase_order_id,
          vendor_invoice_url,
          vendor_invoice_number,
          zoho_bill_url,
          invoice_attachments,
          vendor_creditnote_url,
          vendor_creditnote_attachments,
          branch_name,
          model,
          main_brand,
          part_description,
          final_part_number,
          final_brand_class,
          approved_qty,
          purchase_cost,
          vendor_name,
          receipt_status,
          received_qty,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = invoice_uploaded_by) AS invoice_uploaded_by_name,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = creditnote_uploaded_by) AS creditnote_uploaded_by_name
        FROM filtered
        ORDER BY coalesce(confirmation_date, rfq_date) DESC, order_number, confirmed_item_id
        LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  )
  INTO result;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_counters(p_user_id uuid, p_is_manager boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, ud.user_type AS user_type, (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
      OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
      OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  latest_po_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    ORDER BY pi.confirmed_item_id, po.created_at DESC
  ),
  latest_vcn_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    ORDER BY pi.confirmed_item_id, vcn.created_at DESC
  ),
  item_scope AS (
    SELECT ci.confirmed_item_id, co.confirmed_order_id, qi.customer_id, qi.cost_id, qvi.vendor_id, q.account_manager
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    JOIN user_ctx uc ON true
  ),
  po_missing AS (
    SELECT DISTINCT is_.confirmed_item_id
    FROM item_scope is_
    LEFT JOIN latest_po_by_item lpo ON lpo.confirmed_item_id = is_.confirmed_item_id
    WHERE (coalesce(nullif(trim(lpo.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(lpo.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(lpo.zoho_bill_url), ''), null) IS NULL)
  ),
  rn_missing AS (
    SELECT DISTINCT is_.confirmed_item_id
    FROM item_scope is_
    LEFT JOIN latest_vcn_by_item lvcn ON lvcn.confirmed_item_id = is_.confirmed_item_id
    WHERE lvcn.confirmed_item_id IS NULL
  )
  SELECT jsonb_build_object(
    'missing_purchase_invoices', (SELECT COUNT(*) FROM po_missing),
    'missing_return_invoices', (SELECT COUNT(*) FROM rn_missing)
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_overall_order_summary(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH
  user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id, first_branch.customer_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  per_order AS (
    SELECT
      os.confirmed_order_id,
      BOOL_OR(ci.item_status = 19) AS any_confirmed,
      BOOL_OR(ci.item_status = 23) AS any_delivered,
      BOOL_OR(ci.item_status = 28) AS any_return_requests,
      BOOL_OR(ci.item_status = 24) AS any_cancellation_requests,
      BOOL_OR(ci.item_status = 21) AS any_processing
    FROM order_scope os
    LEFT JOIN qvm_new_apps.confirmed_items ci
      ON ci.confirmed_order_id = os.confirmed_order_id
    GROUP BY os.confirmed_order_id
  ),
  po_missing AS (
    SELECT DISTINCT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = os.confirmed_order_id
    WHERE
      (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
  ),
  rfq_scope AS (
    SELECT DISTINCT q.quotation_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      (uc.is_internal AND (uc.branch_scope IS NULL OR first_branch.customer_id = ANY(uc.branch_scope)))
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  rfq_items AS (
    SELECT qi.quotation_id, qi.item_status
    FROM qvm_new_apps.quotation_items qi
    JOIN rfq_scope rs ON rs.quotation_id = qi.quotation_id
  ),
  rfq_counts AS (
    SELECT
      COUNT(DISTINCT CASE WHEN item_status IN (15, 235, 236) THEN quotation_id END) AS new_rfq,
      COUNT(DISTINCT CASE WHEN item_status IN (16, 237) THEN quotation_id END) AS processing_rfq,
      COUNT(DISTINCT CASE WHEN item_status = 17 THEN quotation_id END) AS priced
    FROM rfq_items
  ),
  order_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE any_confirmed) AS confirmed,
      COUNT(*) FILTER (WHERE any_delivered) AS delivered,
      COUNT(*) FILTER (WHERE any_return_requests) AS return_requests,
      COUNT(*) FILTER (WHERE any_cancellation_requests) AS cancellation_requests,
      COUNT(*) FILTER (WHERE any_processing) AS processing_order
    FROM per_order
  ),
  missing_po AS (
    SELECT COUNT(*) AS missing_purchase_invoices
    FROM po_missing
  )
  SELECT jsonb_build_object(
    'new_rfq', coalesce((SELECT new_rfq FROM rfq_counts),0),
    'processing', coalesce((SELECT processing_rfq FROM rfq_counts),0) + coalesce((SELECT processing_order FROM order_counts),0),
    'priced', coalesce((SELECT priced FROM rfq_counts),0),
    'confirmed', coalesce((SELECT confirmed FROM order_counts),0),
    'delivered', coalesce((SELECT delivered FROM order_counts),0),
    'return_requests', coalesce((SELECT return_requests FROM order_counts),0),
    'cancellation_requests', coalesce((SELECT cancellation_requests FROM order_counts),0),
    'missing_purchase_invoices', coalesce((SELECT missing_purchase_invoices FROM missing_po),0)
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_return_exchange_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_return_type_ids integer[] DEFAULT NULL::integer[], p_status_ids integer[] DEFAULT NULL::integer[], p_branch_ids integer[] DEFAULT NULL::integer[], p_sort_by text DEFAULT 'order_date'::text, p_sort_dir text DEFAULT 'desc'::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
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
    SELECT (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
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
      COALESCE(qi.customer_id, qbr.customer_id)  AS customer_id,
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
    LEFT JOIN LATERAL (
      SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
      WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
      ORDER BY qi0.quotation_item_id ASC LIMIT 1
    ) qbr ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = COALESCE(qi.customer_id, qbr.customer_id)
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
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL
                              OR COALESCE(qi.customer_id, qbr.customer_id) = ANY(uc.branch_scope)))
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
      COALESCE(qi.customer_id, qbr.customer_id)  AS customer_id,
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
    LEFT JOIN LATERAL (
      SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
      WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
      ORDER BY qi0.quotation_item_id ASC LIMIT 1
    ) qbr ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = COALESCE(qi.customer_id, qbr.customer_id)
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
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL
                              OR COALESCE(qi.customer_id, qbr.customer_id) = ANY(uc.branch_scope)))
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

CREATE OR REPLACE FUNCTION public.get_return_exchange_filter_options(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
      FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ), base AS (
    SELECT 
      ri.returned_issue_id,
      ri.status,
      ri.return_type,
      ci.confirmed_item_id AS ci_confirmed_item_id
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN user_ctx uc ON true
    -- The base CTE has no branch on it, so the scope is applied through the item's own quotation
    -- line: a returned issue belongs to the branch its item was raised on.
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL OR EXISTS (
             SELECT 1 FROM qvm_new_apps.quotation_items qi2
              WHERE qi2.quotation_item_id = ci.quotation_item_id
                AND qi2.customer_id = ANY(uc.branch_scope))))
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
$function$;
