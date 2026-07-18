-- QPD-382: Purchase & Return Invoices Dashboard (DB objects)
-- Schema: qvm_new_apps

SET search_path TO qvm_new_apps, public;

-- 1) DDL: Track uploader/source for invoices and credit notes
ALTER TABLE vendor_creditnotes
  ADD COLUMN IF NOT EXISTS uploaded_by uuid,
  ADD COLUMN IF NOT EXISTS uploaded_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS uploaded_source text CHECK (uploaded_source IN ('internal','vendor')) DEFAULT 'internal';

ALTER TABLE purchase_orders
  ADD COLUMN IF NOT EXISTS uploaded_at timestamptz,
  ADD COLUMN IF NOT EXISTS uploaded_source text CHECK (uploaded_source IN ('internal','vendor')) DEFAULT 'internal';

-- 2) Helper: resolve confirmed_order_id from order number
CREATE OR REPLACE FUNCTION public.get_confirmed_order_id_by_order_number(
  p_order_number text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT co.confirmed_order_id
  FROM quotations q
  JOIN confirmed_orders co ON co.quotation_id = q.quotation_id
  WHERE q.order_number = p_order_number
  ORDER BY co.created_at DESC
  LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public.get_confirmed_order_id_by_order_number(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_confirmed_order_id_by_order_number(text) TO authenticated;

-- 3) RPC: Upsert Purchase Invoice (purchase_orders)
CREATE OR REPLACE FUNCTION public.upsert_purchase_invoice(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_vendor_invoice_url text,
  p_vendor_invoice_number text,
  p_uploaded_source text DEFAULT 'internal'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  SELECT purchase_order_id INTO v_purchase_order_id
  FROM purchase_orders
  WHERE confirmed_order_id = p_confirmed_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_purchase_order_id IS NULL THEN
    INSERT INTO purchase_orders(confirmed_order_id, vendor_invoice_url, vendor_invoice_number, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_vendor_invoice_url, p_vendor_invoice_number, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  ELSE
    UPDATE purchase_orders
    SET vendor_invoice_url = p_vendor_invoice_url,
        vendor_invoice_number = p_vendor_invoice_number,
        uploaded_by = p_user_id,
        uploaded_at = now(),
        uploaded_source = COALESCE(NULLIF(p_uploaded_source,''),'internal')
    WHERE purchase_order_id = v_purchase_order_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Purchase invoice saved','purchase_order_id', v_purchase_order_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.upsert_purchase_invoice(uuid, int, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_purchase_invoice(uuid, int, text, text, text) TO authenticated;

-- 4) RPC: Upsert Vendor Credit Note (vendor_creditnotes)
CREATE OR REPLACE FUNCTION public.upsert_vendor_creditnote(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_vendor_creditnote_url text,
  p_vendor_creditnote_number text,
  p_uploaded_source text DEFAULT 'internal'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_vendor_creditnote_id bigint;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  SELECT purchase_order_id INTO v_purchase_order_id
  FROM purchase_orders
  WHERE confirmed_order_id = p_confirmed_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_purchase_order_id IS NULL THEN
    INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  END IF;

  SELECT vendor_creditnote_id INTO v_vendor_creditnote_id
  FROM vendor_creditnotes
  WHERE purchase_order_id = v_purchase_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_vendor_creditnote_id IS NULL THEN
    INSERT INTO vendor_creditnotes(purchase_order_id, vendor_creditnote_url, vendor_creditnote_number, uploaded_by, uploaded_at, uploaded_source)
    VALUES (v_purchase_order_id, p_vendor_creditnote_url, p_vendor_creditnote_number, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING vendor_creditnote_id INTO v_vendor_creditnote_id;
  ELSE
    UPDATE vendor_creditnotes
    SET vendor_creditnote_url = p_vendor_creditnote_url,
        vendor_creditnote_number = p_vendor_creditnote_number,
        uploaded_by = p_user_id,
        uploaded_at = now(),
        uploaded_source = COALESCE(NULLIF(p_uploaded_source,''),'internal')
    WHERE vendor_creditnote_id = v_vendor_creditnote_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Vendor credit note saved','vendor_creditnote_id', v_vendor_creditnote_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.upsert_vendor_creditnote(uuid, int, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_vendor_creditnote(uuid, int, text, text, text) TO authenticated;

-- 5) RPC: Counters for Missing Invoices
CREATE OR REPLACE FUNCTION public.get_purchase_invoices_counters(
  p_user_id uuid,
  p_is_manager boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_missing_pi int := 0;
  v_missing_rn int := 0;
BEGIN
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
  ), base AS (
    SELECT ci.confirmed_item_id, ci.confirmed_order_id,
           po.purchase_order_id,
           po.vendor_invoice_url,
           vcn.vendor_creditnote_url,
           di.delivered_by
    FROM confirmed_items ci
    JOIN confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN purchase_orders po ON po.confirmed_order_id = co.confirmed_order_id
    LEFT JOIN vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    LEFT JOIN di ON di.confirmed_item_id = ci.confirmed_item_id
  )
  SELECT
    COUNT(*) FILTER (WHERE (vendor_invoice_url IS NULL OR length(trim(vendor_invoice_url)) = 0) AND (p_is_manager OR delivered_by = p_user_id)),
    COUNT(*) FILTER (WHERE (vendor_creditnote_url IS NULL OR length(trim(vendor_creditnote_url)) = 0) AND (p_is_manager OR delivered_by = p_user_id))
  INTO v_missing_pi, v_missing_rn
  FROM base;

  RETURN jsonb_build_object(
    'missing_purchase_invoices', v_missing_pi,
    'missing_return_invoices', v_missing_rn
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_purchase_invoices_counters(uuid, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_counters(uuid, boolean) TO authenticated;

-- 6) RPC: Dashboard data with server-side pagination
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
      AND (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
      AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
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
      AND (NOT p_missing_pi OR (i.vendor_invoice_url IS NULL OR length(trim(i.vendor_invoice_url)) = 0))
      AND (NOT p_missing_rn OR (i.vendor_creditnote_url IS NULL OR length(trim(i.vendor_creditnote_url)) = 0))
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
