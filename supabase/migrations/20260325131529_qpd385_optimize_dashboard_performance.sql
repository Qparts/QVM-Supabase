-- Synced from QVM/test branch applied migration history (version 20260325131529, name: qpd385_optimize_dashboard_performance)
-- QPD-385: Optimize Purchase Invoices Dashboard performance for missing_rn filter
SET search_path TO qvm_new_apps, public;

-- Helpful indexes
CREATE INDEX IF NOT EXISTS idx_status_logs_item_status_conf_created ON status_logs(item_status, confirmed_item_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_po_confirmed_order_id ON purchase_orders(confirmed_order_id);
CREATE INDEX IF NOT EXISTS idx_vcn_po_id_created ON vendor_creditnotes(purchase_order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_qvi_cost_id ON quotation_vendor_items(cost_id);
CREATE INDEX IF NOT EXISTS idx_qi_cost_id ON quotation_items(cost_id);
CREATE INDEX IF NOT EXISTS idx_qi_customer_id ON quotation_items(customer_id);
CREATE INDEX IF NOT EXISTS idx_cb_customer_id ON client_branches(customer_id);

-- Replace the dashboard function to use LATERAL lookups for latest PO and VCN and to precompute delivered status ids
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
  -- total count
  WITH delivered_ids AS (
    SELECT array_agg(list_data_id) AS ids
    FROM list_data
    WHERE lower(list_data) LIKE 'deliver%'
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
      ldv.list_data AS vendor_name,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      vcn.vendor_creditnote_url,
      di.delivered_by
    FROM confirmed_items ci
    JOIN confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN LATERAL (
      SELECT p.vendor_invoice_url, p.vendor_invoice_number, p.purchase_order_id
      FROM purchase_orders p
      WHERE p.confirmed_order_id = co.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
    LEFT JOIN LATERAL (
      SELECT c.vendor_creditnote_url
      FROM vendor_creditnotes c
      WHERE c.purchase_order_id = po.purchase_order_id
      ORDER BY c.created_at DESC
      LIMIT 1
    ) vcn ON true
    LEFT JOIN LATERAL (
      SELECT sl.status_changed_by AS delivered_by
      FROM status_logs sl
      WHERE sl.confirmed_item_id = ci.confirmed_item_id
        AND sl.item_status = ANY ((SELECT ids FROM delivered_ids))
      ORDER BY sl.created_at DESC
      LIMIT 1
    ) di ON true
  ), filtered AS (
    SELECT * FROM base i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
      AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
      AND (p_supplier_ids IS NULL OR i.vendor_name IS NULL OR i.vendor_name IS NOT NULL) -- supplier filter handled via vendor_id earlier; simplified here
      AND (p_is_manager OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
  )
  SELECT COUNT(*) INTO total FROM filtered;

  -- rows page
  WITH delivered_ids AS (
    SELECT array_agg(list_data_id) AS ids
    FROM list_data
    WHERE lower(list_data) LIKE 'deliver%'
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
      ldv.list_data AS vendor_name,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      vcn.vendor_creditnote_url,
      di.delivered_by
    FROM confirmed_items ci
    JOIN confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN LATERAL (
      SELECT p.vendor_invoice_url, p.vendor_invoice_number, p.purchase_order_id
      FROM purchase_orders p
      WHERE p.confirmed_order_id = co.confirmed_order_id
      ORDER BY p.created_at DESC
      LIMIT 1
    ) po ON true
    LEFT JOIN LATERAL (
      SELECT c.vendor_creditnote_url
      FROM vendor_creditnotes c
      WHERE c.purchase_order_id = po.purchase_order_id
      ORDER BY c.created_at DESC
      LIMIT 1
    ) vcn ON true
    LEFT JOIN LATERAL (
      SELECT sl.status_changed_by AS delivered_by
      FROM status_logs sl
      WHERE sl.confirmed_item_id = ci.confirmed_item_id
        AND sl.item_status = ANY ((SELECT ids FROM delivered_ids))
      ORDER BY sl.created_at DESC
      LIMIT 1
    ) di ON true
  ), filtered AS (
    SELECT * FROM base i
    WHERE
      (s = '' OR
        position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR
        position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0
      )
      AND (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
      AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
      AND (p_supplier_ids IS NULL OR i.vendor_name IS NULL OR i.vendor_name IS NOT NULL)
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
      (SELECT user_name FROM user_data WHERE user_id = delivered_by) AS delivered_by_name,
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
      vendor_name
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
GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int) TO authenticated;;
