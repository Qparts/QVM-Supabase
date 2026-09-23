-- An invoice belongs to every purchase order its goods sit on, and is filed on the one you chose.
--
-- A purchase order created for a re-buy or a return carries the same items as the order's earlier
-- purchase orders, and the invoices filed on those are its invoices too: both the PO list and the
-- item rows now count them. The attachment RPC files on the purchase order the caller names rather
-- than always the newest one of the order.
DROP FUNCTION IF EXISTS public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text, uuid, integer[]);
CREATE OR REPLACE FUNCTION public.add_purchase_invoice_attachment(p_user_id uuid, p_confirmed_order_id integer, p_file_url text, p_invoice_number text DEFAULT NULL::text, p_file_path text DEFAULT NULL::text, p_mime_type text DEFAULT NULL::text, p_file_size integer DEFAULT NULL::integer, p_uploaded_source text DEFAULT 'internal'::text, p_issued_on date DEFAULT NULL::date, p_payment_term_days integer DEFAULT NULL::integer, p_total_amount numeric DEFAULT NULL::numeric, p_amounts_source text DEFAULT NULL::text, p_invoice_group_id uuid DEFAULT NULL::uuid, p_confirmed_item_ids integer[] DEFAULT NULL::integer[], p_purchase_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_attachment_id bigint;
  v_src text;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = COALESCE(auth.uid(), p_user_id);
  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    IF v_user_type = 205 AND EXISTS (
      SELECT 1
        FROM qvm_new_apps.confirmed_items ci
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
        JOIN qvm_new_apps.user_data ud ON ud.user_vendor = qvi.vendor_id
       WHERE ci.confirmed_order_id = p_confirmed_order_id
         AND ud.user_id = COALESCE(auth.uid(), p_user_id)
    ) THEN
      p_uploaded_source := 'vendor';
    ELSE
      RETURN jsonb_build_object('status','error','message','Access denied');
    END IF;
  END IF;

  IF p_issued_on IS NOT NULL AND p_issued_on > current_date THEN
    RETURN jsonb_build_object('status','error','message','تاريخ الفاتورة لا يمكن أن يكون في المستقبل');
  END IF;

  v_src := CASE
    WHEN p_issued_on IS NULL AND p_total_amount IS NULL AND p_payment_term_days IS NULL THEN NULL
    WHEN p_amounts_source IN ('ai','manual') THEN p_amounts_source
    ELSE 'manual'
  END;

  -- The purchase order the caller is filing on, when it names one of this order's; the newest otherwise.
  IF p_purchase_order_id IS NOT NULL THEN
    SELECT purchase_order_id INTO v_purchase_order_id
    FROM purchase_orders
    WHERE purchase_order_id = p_purchase_order_id AND confirmed_order_id = p_confirmed_order_id;
  END IF;
  IF v_purchase_order_id IS NULL THEN
    SELECT purchase_order_id INTO v_purchase_order_id
    FROM purchase_orders
    WHERE confirmed_order_id = p_confirmed_order_id
    ORDER BY created_at DESC
    LIMIT 1;
  END IF;

  IF v_purchase_order_id IS NULL THEN
    INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  END IF;

  INSERT INTO purchase_invoice_attachments(
    confirmed_order_id, purchase_order_id, file_url, invoice_number, file_path, mime_type, file_size,
    uploaded_by, uploaded_at, uploaded_source, issued_on, payment_term_days, total_amount,
    amounts_source, invoice_group_id
  ) VALUES (
    p_confirmed_order_id, v_purchase_order_id, p_file_url, NULLIF(p_invoice_number,''), p_file_path,
    p_mime_type, p_file_size, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'),
    p_issued_on, COALESCE(p_payment_term_days, 30), p_total_amount, v_src,
    COALESCE(p_invoice_group_id, gen_random_uuid())
  ) RETURNING attachment_id INTO v_attachment_id;

  -- Only lines that belong to the order being filed against. A caller naming someone else's line
  -- gets it dropped rather than the whole upload refused: the rest of the invoice is still true.
  IF p_confirmed_item_ids IS NOT NULL AND array_length(p_confirmed_item_ids, 1) > 0 THEN
    INSERT INTO qvm_new_apps.purchase_invoice_lines(attachment_id, confirmed_item_id)
    SELECT v_attachment_id, ci.confirmed_item_id
      FROM qvm_new_apps.confirmed_items ci
     WHERE ci.confirmed_item_id = ANY (p_confirmed_item_ids)
       AND ci.confirmed_order_id = p_confirmed_order_id
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object('status','success','message','Attachment added',
    'attachment_id', v_attachment_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.add_purchase_invoice_attachment(uuid, integer, text, text, text, text, integer, text, date, integer, numeric, text, uuid, integer[], bigint) TO authenticated;

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
      -- A line taken off the order entirely (by the vendor, or by an approved cancellation) is
      -- cancelled, not "not received": there is nothing left to receive.
      count(*) FILTER (WHERE (pi.receipt_status IS NULL OR pi.receipt_status = 'not_received')
                         AND NOT cx.is_cancelled)                                          AS not_received_count,
      count(*) FILTER (WHERE cx.is_cancelled)                                               AS cancelled_count,
      sum(cx.cancelled_qty)                                                                 AS total_cancelled_qty,
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
    CROSS JOIN LATERAL (
      SELECT cq.cancelled_qty,
             (COALESCE(pi.approved_qty, 0) = 0
              AND COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                             WHERE ri.purchase_item_id = pi.purchase_item_id), 0) = 0
              AND (cq.cancelled_qty > 0 OR pi.vendor_item_status = 160 OR ci.item_status = 18)) AS is_cancelled
      FROM (SELECT COALESCE(sum(c.qty), 0)::int AS cancelled_qty
              FROM qvm_new_apps.quotation_item_cancellations c
             WHERE c.purchase_item_id = pi.purchase_item_id) cq
    ) cx
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
      a.cancelled_count, a.total_cancelled_qty,
      a.returned_count, a.total_approved_qty, a.total_returned_qty, a.total_value,
      po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url,
      -- The invoice files filed on this purchase order, or on a holder purchase order of its order.
      inv.pi_attachment_count, inv.first_invoice_url, inv.invoice_numbers,
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
      SELECT count(*)::int AS pi_attachment_count,
             (array_agg(a.file_url ORDER BY a.uploaded_at DESC))[1] AS first_invoice_url,
             string_agg(DISTINCT NULLIF(btrim(a.invoice_number), ''), ', ') AS invoice_numbers
        FROM qvm_new_apps.purchase_invoice_attachments a
       WHERE a.cancelled_at IS NULL
         -- Filed on this purchase order, on a holder purchase order of the order (no items), or on
         -- another purchase order of the order that carries the same items — an invoice for the goods
         -- belongs to every purchase order those goods sit on.
         AND (a.purchase_order_id = po.purchase_order_id
                  OR (a.confirmed_order_id = po.confirmed_order_id
                      AND (NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items hx WHERE hx.purchase_order_id = a.purchase_order_id)
                           OR EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items x
                                       JOIN qvm_new_apps.purchase_items y ON y.confirmed_item_id = x.confirmed_item_id
                                      WHERE x.purchase_order_id = a.purchase_order_id AND y.purchase_order_id = po.purchase_order_id))))
    ) inv ON true
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
        AND COALESCE(b.pi_attachment_count, 0) = 0
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
               cancelled_count, total_cancelled_qty,
               returned_count, total_approved_qty, total_returned_qty, total_value,
               vendor_invoice_url, vendor_invoice_number, zoho_bill_url, vcn_count,
               pi_attachment_count, first_invoice_url, invoice_numbers
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
  -- An invoice belongs to the purchase order it was filed on, or to the order as a whole when it
  -- was filed on a holder purchase order (one with no items — how older uploads stored their file).
  -- Asked about one purchase order, only its own and the order's holders count, so a line that sits
  -- on two purchase orders does not borrow the other one's invoice.
  attachments_per_item AS (
    SELECT pi.confirmed_item_id, COALESCE(array_agg(pia.file_url ORDER BY pia.uploaded_at DESC), ARRAY[]::text[]) AS invoice_attachments
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.purchase_invoice_attachments pia
      ON pia.cancelled_at IS NULL
     AND (pia.purchase_order_id = po.purchase_order_id
          OR (pia.confirmed_order_id = po.confirmed_order_id
              AND (NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items hx WHERE hx.purchase_order_id = pia.purchase_order_id)
                   OR EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items x WHERE x.purchase_order_id = pia.purchase_order_id AND x.confirmed_item_id = pi.confirmed_item_id))))
    WHERE p_purchase_order_id IS NULL OR pi.purchase_order_id = p_purchase_order_id
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

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 50 $$;
