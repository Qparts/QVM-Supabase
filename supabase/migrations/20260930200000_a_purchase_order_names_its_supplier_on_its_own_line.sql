-- A purchase order names its supplier and its client on its own line.
--
-- purchase_orders.vendor_id is empty on the orders the current purchase path raises, so the
-- purchase orders page showed no supplier on the order line. Two things: the orders whose lines
-- all point at one vendor's priced line get that vendor written in, and the page's function
-- falls back to the lines' vendor for any order still without one. The line also gets the
-- client company beside the branch.

set search_path to qvm_new_apps, public;

with line_vendor as (
  select pi.purchase_order_id, qvi.vendor_id
    from qvm_new_apps.purchase_items pi
    join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
    join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = coalesce(pi.cost_id, qi.selected_cost_id, qi.cost_id)
), one_vendor as (
  select purchase_order_id, min(vendor_id) as vendor_id
    from line_vendor group by purchase_order_id having count(distinct vendor_id) = 1
)
update qvm_new_apps.purchase_orders po
   set vendor_id = ov.vendor_id
  from one_vendor ov
 where ov.purchase_order_id = po.purchase_order_id and po.vendor_id is null;

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
      -- The supplier: the purchase order's own vendor, else the vendor of the priced line its items
      -- were bought from — a purchase order raised without vendor_id still names who it went to.
      COALESCE(vnd.vendor_name, lv.vendor_name) AS vendor_name,
      COALESCE(po.vendor_id, lv.vendor_id) AS vendor_id,
      cb.branch_name,
      COALESCE(vcc.name, ld_client.list_data) AS client_name,
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
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.v_client_companies vcc ON vcc.company_id = cb.list_data_id
    LEFT JOIN LATERAL (
      SELECT v2.vendor_id, v2.vendor_name
        FROM qvm_new_apps.purchase_items pi2
        JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = pi2.confirmed_item_id
        JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi2 ON qvi2.cost_id = COALESCE(pi2.cost_id, qi2.selected_cost_id, qi2.cost_id)
        JOIN qvm_new_apps.vendors v2 ON v2.vendor_id = qvi2.vendor_id
       WHERE pi2.purchase_order_id = po.purchase_order_id
       ORDER BY pi2.purchase_item_id
       LIMIT 1
    ) lv ON true
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
               vendor_name, vendor_id, branch_name, client_name, created_by, created_by_name,
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