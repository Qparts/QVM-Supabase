-- QPD-382: Purchase & Return Invoices Dashboard - OR semantics when both missing flags are selected
-- This migration updates get_purchase_invoices_dashboard to return a UNION-like (OR) filter
-- when both p_missing_pi and p_missing_rn are true. Previously, both flags applied with AND
-- semantics and only returned items missing both.

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_dashboard(
  p_user_id uuid,
  p_is_manager boolean DEFAULT false,
  p_search text DEFAULT NULL,
  p_missing_pi boolean DEFAULT FALSE,
  p_missing_rn boolean DEFAULT FALSE,
  p_account_manager uuid DEFAULT NULL,
  p_branch_ids int[] DEFAULT NULL,
  p_supplier_ids int[] DEFAULT NULL,
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
  -- Statement 1: total count
  WITH delivered AS (
    SELECT sl.confirmed_item_id,
           sl.status_changed_by,
           sl.created_at,
           row_number() OVER (PARTITION BY sl.confirmed_item_id ORDER BY sl.created_at DESC) AS rn
    FROM status_logs sl
    JOIN list_data ld ON ld.list_data_id = sl.item_status
    WHERE lower(ld.list_data) LIKE '%deliver%'
  ), di AS (
    SELECT d.confirmed_item_id, d.status_changed_by AS delivered_by
    FROM delivered d
    WHERE d.rn = 1
  ), items AS (
    SELECT 
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at AS rfq_date,
      co.created_at AS confirmation_date,
      q.account_manager,
      uam.user_name AS account_manager_name,
      q.service_advisor,
      usa.user_name AS service_advisor_name,
      qi.customer_id,
      cb.branch_name,
      qi.model,
      qi.main_brand AS main_brand_id,
      ldb.list_data AS main_brand,
      qi.part_description,
      ci.final_part_number,
      ci.final_brand_class AS final_brand_class_id,
      ldf.list_data AS final_brand_class,
      ci.approved_qty,
      qvi.cost AS purchase_cost,
      qvi.vendor_id,
      ldv.list_data AS vendor_name,
      po.purchase_order_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.uploaded_by AS po_uploaded_by,
      po.uploaded_at AS po_uploaded_at,
      po.uploaded_source AS po_uploaded_source,
      vcn.vendor_creditnote_url,
      vcn.vendor_creditnote_number,
      vcn.uploaded_by AS vcn_uploaded_by,
      vcn.uploaded_at AS vcn_uploaded_at,
      vcn.uploaded_source AS vcn_uploaded_source,
      di.delivered_by,
      udel.user_name AS delivered_by_name
    FROM confirmed_items ci
    JOIN confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN user_data uam ON uam.user_id = q.account_manager
    LEFT JOIN user_data usa ON usa.user_id = q.service_advisor
    LEFT JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    LEFT JOIN di ON di.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN user_data udel ON udel.user_id = di.delivered_by
  ), filtered AS (
    SELECT * FROM items i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (
        CASE
          WHEN p_missing_pi AND p_missing_rn THEN
            ((i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0)
             OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
          ELSE
            (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
            AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
        END
      )
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
      AND (p_supplier_ids IS NULL OR i.vendor_id = ANY(p_supplier_ids))
      AND (p_is_manager OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
  )
  SELECT COUNT(*) INTO total FROM filtered;

  -- Statement 2: paginated rows
  WITH delivered AS (
    SELECT sl.confirmed_item_id,
           sl.status_changed_by,
           sl.created_at,
           row_number() OVER (PARTITION BY sl.confirmed_item_id ORDER BY sl.created_at DESC) AS rn
    FROM status_logs sl
    JOIN list_data ld ON ld.list_data_id = sl.item_status
    WHERE lower(ld.list_data) LIKE '%deliver%'
  ), di AS (
    SELECT d.confirmed_item_id, d.status_changed_by AS delivered_by
    FROM delivered d
    WHERE d.rn = 1
  ), items AS (
    SELECT 
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at AS rfq_date,
      co.created_at AS confirmation_date,
      q.account_manager,
      uam.user_name AS account_manager_name,
      q.service_advisor,
      usa.user_name AS service_advisor_name,
      qi.customer_id,
      cb.branch_name,
      qi.model,
      qi.main_brand AS main_brand_id,
      ldb.list_data AS main_brand,
      qi.part_description,
      ci.final_part_number,
      ci.final_brand_class AS final_brand_class_id,
      ldf.list_data AS final_brand_class,
      ci.approved_qty,
      qvi.cost AS purchase_cost,
      qvi.vendor_id,
      ldv.list_data AS vendor_name,
      po.purchase_order_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.uploaded_by AS po_uploaded_by,
      po.uploaded_at AS po_uploaded_at,
      po.uploaded_source AS po_uploaded_source,
      vcn.vendor_creditnote_url,
      vcn.vendor_creditnote_number,
      vcn.uploaded_by AS vcn_uploaded_by,
      vcn.uploaded_at AS vcn_uploaded_at,
      vcn.uploaded_source AS vcn_uploaded_source,
      di.delivered_by,
      udel.user_name AS delivered_by_name
    FROM confirmed_items ci
    JOIN confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN user_data uam ON uam.user_id = q.account_manager
    LEFT JOIN user_data usa ON usa.user_id = q.service_advisor
    LEFT JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    LEFT JOIN di ON di.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN user_data udel ON udel.user_id = di.delivered_by
  ), filtered AS (
    SELECT * FROM items i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (
        CASE
          WHEN p_missing_pi AND p_missing_rn THEN
            ((i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0)
             OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
          ELSE
            (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
            AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
        END
      )
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
      AND (p_supplier_ids IS NULL OR i.vendor_id = ANY(p_supplier_ids))
      AND (p_is_manager OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
  )
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO rows
  FROM (
    SELECT 
      confirmed_item_id,
      confirmed_order_id,
      order_number,
      rfq_date,
      confirmation_date,
      delivered_by_name,
      vendor_invoice_url,
      vendor_invoice_number,
      vendor_creditnote_url,
      branch_name,
      model,
      main_brand,
      part_description,
      final_part_number,
      final_brand_class,
      approved_qty,
      purchase_cost,
      vendor_name,
      (SELECT user_name FROM user_data WHERE user_id = po_uploaded_by) AS invoice_uploaded_by_name,
      (SELECT user_name FROM user_data WHERE user_id = vcn_uploaded_by) AS creditnote_uploaded_by_name
    FROM filtered
    ORDER BY coalesce(confirmation_date, rfq_date) DESC, order_number, confirmed_item_id
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

REVOKE EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) TO authenticated;
