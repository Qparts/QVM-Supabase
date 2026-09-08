-- The receipt has a number, and a returned item says so on the purchase-orders list.
--
-- Two small gaps. The goods-receipt document showed only 'PO-<id>' while the purchase-order modal
-- lists each round as 'PO-<id>-<round>' — the same receipt under two names. And the list's Receipt
-- Status column counted a return only when the goods went back to the vendor, so a client return
-- kept in stock left the line reading as plainly received.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_receipt_round_document(p_receipt_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_po_id bigint;
  v_result jsonb;
BEGIN
  SELECT purchase_order_id INTO v_po_id
  FROM qvm_new_apps.purchase_receipt_rounds WHERE receipt_round_id = p_receipt_round_id;

  IF v_po_id IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'Receipt round not found', 'data', null);
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', null);
  END IF;

  WITH lines AS (
    SELECT
      ri.purchase_item_id,
      ri.receipt_status,
      COALESCE(ri.received_qty, 0) AS received_qty,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data AS final_brand_class,
      COALESCE(qvi.cost, 0) AS unit_cost,
      COALESCE(qvi.cost, 0) * COALESCE(ri.received_qty, 0) AS line_total
    FROM qvm_new_apps.purchase_receipt_round_items ri
    JOIN qvm_new_apps.purchase_items pi ON pi.purchase_item_id = ri.purchase_item_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE ri.receipt_round_id = p_receipt_round_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'receipt_round_id', r.receipt_round_id,
      'round_no', r.round_no,
      'purchase_order_id', po.purchase_order_id,
      'po_ref', 'PO-' || po.purchase_order_id,
      -- The same number the purchase-order modal lists this round under, so the document and
      -- the list refer to the receipt by one name.
      'receipt_number', 'PO-' || po.purchase_order_id || '-' || r.receipt_round_id,
      'po_number', r.po_number,
      'signature', r.signature,
      'signed_note_at', r.signed_note_at,
      'signed_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = r.signed_by),
      'received_at', r.signed_at,
      'order_number', q.order_number,
      'confirmation_date', co.created_at,
      'vendor_name', vnd.vendor_name,
      'plate_number', q.plate_number,
      'vin', (SELECT qi2.vin FROM qvm_new_apps.quotation_items qi2 WHERE qi2.quotation_id = q.quotation_id AND qi2.vin IS NOT NULL LIMIT 1),
      'brand', (SELECT ld.list_data FROM qvm_new_apps.quotation_items qi3
                LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi3.main_brand
                WHERE qi3.quotation_id = q.quotation_id LIMIT 1),
      'model', (SELECT qi4.model FROM qvm_new_apps.quotation_items qi4 WHERE qi4.quotation_id = q.quotation_id AND qi4.model IS NOT NULL LIMIT 1),
      'items', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.purchase_item_id) FROM lines l), '[]'::jsonb),
      'total_before_vat', COALESCE((SELECT sum(line_total) FROM lines), 0),
      'vat_amount', ROUND(COALESCE((SELECT sum(line_total) FROM lines), 0) * 0.15, 2),
      'total_with_vat', ROUND(COALESCE((SELECT sum(line_total) FROM lines), 0) * 1.15, 2)
    )
  ) INTO v_result
  FROM qvm_new_apps.purchase_receipt_rounds r
  JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = r.purchase_order_id
  JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
  WHERE r.receipt_round_id = p_receipt_round_id;

  RETURN v_result;
END;
$function$;

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
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, (ud.user_type = 185) AS is_internal
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
    WHERE uc.is_internal
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
