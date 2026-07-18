-- Fix: resolve the correct purchase_order per confirmed_item.
-- When a user uploads an invoice for specific selected items, upsert_purchase_order_items
-- creates purchase_items rows linking that PO to those specific confirmed_item_ids.
-- We first try to find the PO via purchase_items (item-level), and fall back to
-- the latest PO by confirmed_order_id for items not yet linked to a specific PO.
BEGIN;

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
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_delivered_ids int[];
  result jsonb;
BEGIN
  SELECT COALESCE(array_agg(list_data_id), ARRAY[]::int[]) INTO v_delivered_ids
  FROM qvm_new_apps.list_data
  WHERE lower(list_data) LIKE 'deliver%';

  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, ud.user_type AS user_type, (ud.user_type = 185) AS is_internal
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
    WHERE uc.is_internal
       OR (uc.user_role = 170 AND EXISTS (
            SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  latest_po_by_order AS (
    SELECT t.confirmed_order_id, t.purchase_order_id, t.vendor_invoice_url, t.vendor_invoice_number, t.zoho_bill_url, t.uploaded_by AS invoice_uploaded_by
    FROM (
      SELECT po.confirmed_order_id, po.purchase_order_id, po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url, po.uploaded_by,
             row_number() OVER (PARTITION BY po.confirmed_order_id ORDER BY po.created_at DESC) AS rn
      FROM qvm_new_apps.purchase_orders po
    ) t
    WHERE t.rn = 1
  ),
  latest_vcn_by_order AS (
    SELECT t.confirmed_order_id, t.vendor_creditnote_url, t.uploaded_by AS creditnote_uploaded_by
    FROM (
      SELECT po.confirmed_order_id, vcn.vendor_creditnote_url, vcn.uploaded_by,
             row_number() OVER (PARTITION BY po.confirmed_order_id ORDER BY vcn.created_at DESC) AS rn
      FROM qvm_new_apps.vendor_creditnotes vcn
      JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = vcn.purchase_order_id
    ) t
    WHERE t.rn = 1
  ),
  attachments_per_order AS (
    SELECT confirmed_order_id, COALESCE(array_agg(file_url ORDER BY uploaded_at DESC), ARRAY[]::text[]) AS invoice_attachments
    FROM qvm_new_apps.purchase_invoice_attachments
    GROUP BY confirmed_order_id
  ),
  vcn_attachments_per_order AS (
    SELECT po.confirmed_order_id, COALESCE(array_agg(vcn.vendor_creditnote_url ORDER BY vcn.created_at DESC), ARRAY[]::text[]) AS vendor_creditnote_attachments
    FROM qvm_new_apps.vendor_creditnotes vcn
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = vcn.purchase_order_id
    GROUP BY po.confirmed_order_id
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
      lpo.vendor_invoice_url,
      lpo.vendor_invoice_number,
      lpo.zoho_bill_url,
      lpo.invoice_uploaded_by,
      lvcn.creditnote_uploaded_by,
      lvcn.vendor_creditnote_url,
      ao.invoice_attachments,
      vao.vendor_creditnote_attachments,
      ld.status_changed_by AS delivered_by,
      uc.is_internal AS is_internal_user
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
    LEFT JOIN latest_po_by_order lpo ON lpo.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN latest_vcn_by_order lvcn ON lvcn.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN attachments_per_order ao ON ao.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN vcn_attachments_per_order vao ON vao.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN latest_delivered ld ON ld.confirmed_item_id = ci.confirmed_item_id
  ),
  filtered AS (
    SELECT * FROM base i
    WHERE (s = '' OR position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (
        CASE
          WHEN p_missing_pi AND p_missing_rn THEN
            (
              i.confirmed_order_id IN (
                SELECT os.confirmed_order_id FROM order_scope os
                LEFT JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = os.confirmed_order_id
                WHERE (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
                  AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
                  AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
              )
              OR
              i.confirmed_order_id IN (
                SELECT os.confirmed_order_id FROM order_scope os
                LEFT JOIN LATERAL (
                  SELECT p.purchase_order_id FROM qvm_new_apps.purchase_orders p WHERE p.confirmed_order_id = os.confirmed_order_id ORDER BY p.created_at DESC LIMIT 1
                ) po ON true
                WHERE po.purchase_order_id IS NULL OR NOT EXISTS (
                  SELECT 1 FROM qvm_new_apps.vendor_creditnotes c WHERE c.purchase_order_id = po.purchase_order_id
                )
              )
            )
          ELSE
            (NOT p_missing_pi OR i.confirmed_order_id IN (
              SELECT os.confirmed_order_id FROM order_scope os
              LEFT JOIN qvm_new_apps.purchase_orders po ON po.confirmed_order_id = os.confirmed_order_id
              WHERE (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
                AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
                AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
            ))
            AND (NOT p_missing_rn OR i.confirmed_order_id IN (
              SELECT os.confirmed_order_id FROM order_scope os
              LEFT JOIN LATERAL (
                SELECT p.purchase_order_id FROM qvm_new_apps.purchase_orders p WHERE p.confirmed_order_id = os.confirmed_order_id ORDER BY p.created_at DESC LIMIT 1
              ) po ON true
              WHERE po.purchase_order_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM qvm_new_apps.vendor_creditnotes c WHERE c.purchase_order_id = po.purchase_order_id
              )
            ))
        END
      )
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
      AND (p_is_manager OR i.is_internal_user OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
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

REVOKE EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) TO authenticated;

COMMIT;
