-- Vendor Performance Reports tab: per-vendor Confirmed vs. Lost order VALUE (SAR), matching the
-- "Order Value per Supplier" pattern already used as demo data in the legacy Suppliers Reports tab.
--
--   Confirmed value = sum(cost * quantity) for items this vendor actually won (qi.cost_id =
--     qvi.cost_id) AND that reached a real purchase order (via purchase_items -> confirmed_items).
--   Lost value = sum(cost * quantity) for every priced item belonging to a vendor-quotation
--     (a single quotation_vendors row) where NONE of that vendor's items on that RFQ were
--     purchased — a total-loss RFQ from the vendor's perspective, not merely "this one item lost."
--     A vendor-quotation where some items won and others didn't only contributes its winning
--     items to Confirmed; the non-winning ones on that same (partially-won) quotation are not
--     counted as Lost, since the user's own phrasing was "quotations that have NO items purchased
--     from it."
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_confirmed_vs_lost_value_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  WITH scoped_items AS (
    SELECT qi.quotation_item_id, qi.cost_id, qi.quantity
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  vendor_items AS (
    SELECT
      qvi.quotation_vendor_id,
      qvi.vendor_id,
      qvi.cost,
      si.quantity,
      (
        si.cost_id = qvi.cost_id
        AND EXISTS (
          SELECT 1
          FROM qvm_new_apps.confirmed_items ci
          JOIN qvm_new_apps.purchase_items pi ON pi.confirmed_item_id = ci.confirmed_item_id
          WHERE ci.quotation_item_id = si.quotation_item_id
        )
      ) AS is_purchased
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN scoped_items si ON si.quotation_item_id = qvi.quotation_item_id
    WHERE qvi.cost IS NOT NULL
  ),
  qv_any_purchased AS (
    SELECT quotation_vendor_id, bool_or(is_purchased) AS any_purchased
    FROM vendor_items
    GROUP BY quotation_vendor_id
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY (r.confirmed_value + r.lost_value) DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      v.vendor_id,
      v.vendor_name,
      round(sum(CASE WHEN vi.is_purchased THEN vi.cost * vi.quantity ELSE 0 END)::numeric, 2) AS confirmed_value,
      round(sum(CASE WHEN NOT qap.any_purchased THEN vi.cost * vi.quantity ELSE 0 END)::numeric, 2) AS lost_value
    FROM vendor_items vi
    JOIN qv_any_purchased qap ON qap.quotation_vendor_id = vi.quotation_vendor_id
    JOIN qvm_new_apps.vendors v ON v.vendor_id = vi.vendor_id
    GROUP BY v.vendor_id, v.vendor_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_confirmed_vs_lost_value_report(integer, timestamptz, timestamptz) TO authenticated;
