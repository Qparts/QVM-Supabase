-- Synced from QVM/test branch applied migration history (version 20260325231953, name: qpd385_fix_integer_equals_array_rpc)
-- QPD-385: Eliminate integer = integer[] errors by using typed local arrays and ANY() safely
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
  rows jsonb;
  total_rows int;
  total_orders int;
BEGIN
  -- Cache delivered status ids into a local array for type safety
  SELECT COALESCE(array_agg(list_data_id), ARRAY[]::int[]) INTO v_delivered_ids
  FROM qvm_new_apps.list_data
  WHERE lower(list_data) LIKE 'deliver%';

  -- 1) Totals (items and orders) with aligned missing PI semantics
  WITH user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ), order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
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
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ), po_missing AS (
    -- PI missing per order (align with overall summary): url, number, zoho all empty (or no PO row)
    SELECT DISTINCT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = os.confirmed_order_id
    WHERE
      (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
  ), rn_missing AS (
    -- RN missing per order: latest PO exists but no credit note row (or no PO at all)
    SELECT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN LATERAL (
      SELECT p.purchase_order_id
      FROM qvm_new_apps.purchase_orders p
      WHERE p.confirmed_order_id = os.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
    WHERE po.purchase_order_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_creditnotes c WHERE c.purchase_order_id = po.purchase_order_id)
  ), base AS (
    SELECT 
      ci.confirmed_item_id,
      co.confirmed_order_id,
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
      ldv.list_data AS vendor_name,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url,
      (SELECT sl.status_changed_by
         FROM qvm_new_apps.status_logs sl
        WHERE sl.confirmed_item_id = ci.confirmed_item_id
          AND sl.item_status = ANY(v_delivered_ids)
        ORDER BY sl.created_at DESC
        LIMIT 1) AS delivered_by
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN LATERAL (
      SELECT p.vendor_invoice_url, p.vendor_invoice_number, p.zoho_bill_url, p.purchase_order_id
      FROM qvm_new_apps.purchase_orders p
      WHERE p.confirmed_order_id = co.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
  ), filtered AS (
    SELECT * FROM base i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (NOT p_missing_pi OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM po_missing))
      AND (NOT p_missing_rn OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM rn_missing))
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
  )
  SELECT COUNT(*) INTO total_rows FROM filtered;

  -- Also compute distinct orders count (for matching summary totals)
  WITH user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ), order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
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
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ), po_missing AS (
    SELECT DISTINCT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = os.confirmed_order_id
    WHERE
      (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
  ), rn_missing AS (
    SELECT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN LATERAL (
      SELECT p.purchase_order_id
      FROM qvm_new_apps.purchase_orders p
      WHERE p.confirmed_order_id = os.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
    WHERE po.purchase_order_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_creditnotes c WHERE c.purchase_order_id = po.purchase_order_id)
  ), base AS (
    SELECT 
      ci.confirmed_item_id,
      co.confirmed_order_id,
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
      ldv.list_data AS vendor_name,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url,
      (SELECT sl.status_changed_by
         FROM qvm_new_apps.status_logs sl
        WHERE sl.confirmed_item_id = ci.confirmed_item_id
          AND sl.item_status = ANY(v_delivered_ids)
        ORDER BY sl.created_at DESC
        LIMIT 1) AS delivered_by
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN LATERAL (
      SELECT p.vendor_invoice_url, p.vendor_invoice_number, p.zoho_bill_url, p.purchase_order_id
      FROM qvm_new_apps.purchase_orders p
      WHERE p.confirmed_order_id = co.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
  ), filtered AS (
    SELECT * FROM base i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (NOT p_missing_pi OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM po_missing))
      AND (NOT p_missing_rn OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM rn_missing))
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
  )
  SELECT COUNT(DISTINCT confirmed_order_id) INTO total_orders FROM filtered;

  -- 2) Paged rows
  WITH user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ), order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
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
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ), base AS (
    SELECT 
      ci.confirmed_item_id,
      co.confirmed_order_id,
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
      ldv.list_data AS vendor_name,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url,
      (SELECT sl.status_changed_by
         FROM qvm_new_apps.status_logs sl
        WHERE sl.confirmed_item_id = ci.confirmed_item_id
          AND sl.item_status = ANY(v_delivered_ids)
        ORDER BY sl.created_at DESC
        LIMIT 1) AS delivered_by
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN LATERAL (
      SELECT p.vendor_invoice_url, p.vendor_invoice_number, p.zoho_bill_url, p.purchase_order_id
      FROM qvm_new_apps.purchase_orders p
      WHERE p.confirmed_order_id = co.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
  ), filtered AS (
    SELECT * FROM base i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (NOT p_missing_pi OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM po_missing))
      AND (NOT p_missing_rn OR i.confirmed_order_id IN (SELECT confirmed_order_id FROM rn_missing))
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
  )
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO rows
  FROM (
    SELECT 
      confirmed_item_id,
      confirmed_order_id,
      order_number,
      rfq_date,
      confirmation_date,
      (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = delivered_by) AS delivered_by_name,
      vendor_invoice_url,
      vendor_invoice_number,
      zoho_bill_url,
      branch_name,
      model,
      main_brand,
      part_description,
      final_part_number,
      final_brand_class,
      approved_qty,
      purchase_cost,
      vendor_name
    FROM filtered
    ORDER BY coalesce(confirmation_date, rfq_date) DESC, order_number, confirmed_item_id
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'status','success',
    'message','OK',
    'total', total_rows,
    'orders_total', total_orders,
    'rows', rows
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) TO authenticated;;
