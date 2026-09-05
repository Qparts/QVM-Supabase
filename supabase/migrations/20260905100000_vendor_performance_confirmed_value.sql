-- Vendor Performance report: add confirmed_value — the SAR amount of purchase orders per vendor,
-- shown beside the "Confirmed to Orders" count. Value comes from quotation_vendor_items.cost x
-- confirmed_items.approved_qty (purchase_items.final_purchase_price is never populated in this
-- schema, confirmed live), matching how the PO-level dashboard already computes its totals.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_performance_report(p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.received_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendors qv
        WHERE qv.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR qv.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi
            WHERE qi.quotation_id = qv.quotation_id AND qi.customer_id = p_branch_id
          ))
      ) AS received_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qv.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR qv.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi
            WHERE qi.quotation_id = qv.quotation_id AND qi.customer_id = p_branch_id
          ))
      ) AS received_items,
      (
        SELECT count(DISTINCT qvi.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv2 ON qv2.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qvi.vendor_id = v.vendor_id
          AND qvi.cost IS NOT NULL AND qvi.cost > 0
          AND (p_date_from IS NULL OR qv2.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv2.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = qv2.quotation_id AND qi2.customer_id = p_branch_id
          ))
      ) AS priced_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi
        JOIN qvm_new_apps.quotation_vendors qv2 ON qv2.quotation_vendor_id = qvi.quotation_vendor_id
        WHERE qvi.vendor_id = v.vendor_id
          AND qvi.cost IS NOT NULL AND qvi.cost > 0
          AND (p_date_from IS NULL OR qv2.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv2.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = qv2.quotation_id AND qi2.customer_id = p_branch_id
          ))
      ) AS priced_items,
      (
        SELECT count(*)
        FROM qvm_new_apps.purchase_orders po
        WHERE po.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci
            JOIN qvm_new_apps.quotation_items qi3 ON qi3.quotation_item_id = ci.quotation_item_id
            WHERE ci.confirmed_order_id = po.confirmed_order_id AND qi3.customer_id = p_branch_id
          ))
      ) AS confirmed_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.purchase_items pi
        JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
        WHERE po.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci2
            JOIN qvm_new_apps.quotation_items qi3b ON qi3b.quotation_item_id = ci2.quotation_item_id
            WHERE ci2.confirmed_order_id = po.confirmed_order_id AND qi3b.customer_id = p_branch_id
          ))
      ) AS confirmed_items,
      (
        SELECT COALESCE(sum(COALESCE(qvi5v.cost, 0) * COALESCE(ci5v.approved_qty, 0)), 0)
        FROM qvm_new_apps.purchase_items pi5v
        JOIN qvm_new_apps.purchase_orders po5v ON po5v.purchase_order_id = pi5v.purchase_order_id
        JOIN qvm_new_apps.confirmed_items ci5v ON ci5v.confirmed_item_id = pi5v.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi5v ON qi5v.quotation_item_id = ci5v.quotation_item_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi5v ON qvi5v.cost_id = qi5v.cost_id
        WHERE po5v.vendor_id = v.vendor_id
          AND (p_date_from IS NULL OR po5v.created_at >= p_date_from)
          AND (p_date_to IS NULL OR po5v.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.confirmed_items ci5vb
            JOIN qvm_new_apps.quotation_items qi5vb ON qi5vb.quotation_item_id = ci5vb.quotation_item_id
            WHERE ci5vb.confirmed_order_id = po5v.confirmed_order_id AND qi5vb.customer_id = p_branch_id
          ))
      ) AS confirmed_value,
      (
        SELECT count(DISTINCT qi4.quotation_id)
        FROM qvm_new_apps.quotation_items qi4
        JOIN qvm_new_apps.quotation_vendor_items qvi4 ON qvi4.cost_id = qi4.cost_id
        JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = qi4.quotation_id
        WHERE qvi4.vendor_id = v.vendor_id
          AND qi4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR q4.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q4.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi4.customer_id = p_branch_id)
      ) AS delivered_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_items qi4
        JOIN qvm_new_apps.quotation_vendor_items qvi4 ON qvi4.cost_id = qi4.cost_id
        JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = qi4.quotation_id
        WHERE qvi4.vendor_id = v.vendor_id
          AND qi4.item_status IN (23, 31)
          AND (p_date_from IS NULL OR q4.created_at >= p_date_from)
          AND (p_date_to IS NULL OR q4.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR qi4.customer_id = p_branch_id)
      ) AS delivered_items,
      (
        SELECT count(DISTINCT qvi5.quotation_vendor_id)
        FROM qvm_new_apps.quotation_vendor_items qvi5
        JOIN qvm_new_apps.quotation_vendors qv5 ON qv5.quotation_vendor_id = qvi5.quotation_vendor_id
        WHERE qvi5.vendor_id = v.vendor_id
          AND qvi5.vendor_item_status = 161
          AND (p_date_from IS NULL OR qv5.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv5.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi5
            WHERE qi5.quotation_id = qv5.quotation_id AND qi5.customer_id = p_branch_id
          ))
      ) AS unavailable_count,
      (
        SELECT count(*)
        FROM qvm_new_apps.quotation_vendor_items qvi5
        JOIN qvm_new_apps.quotation_vendors qv5 ON qv5.quotation_vendor_id = qvi5.quotation_vendor_id
        WHERE qvi5.vendor_id = v.vendor_id
          AND qvi5.vendor_item_status = 161
          AND (p_date_from IS NULL OR qv5.created_at >= p_date_from)
          AND (p_date_to IS NULL OR qv5.created_at <= p_date_to)
          AND (p_branch_id IS NULL OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi5
            WHERE qi5.quotation_id = qv5.quotation_id AND qi5.customer_id = p_branch_id
          ))
      ) AS unavailable_items
    FROM qvm_new_apps.vendors v
  ) r;

  RETURN v_result;
END;
$function$;
