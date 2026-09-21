-- A re-issued line needs nobody's approval again.
--
-- A vendor's cancellation applies at once; the quantity it frees, put back on the order as a new
-- line, was already approved as its parent. The desk confirms such a line directly whatever the
-- customer's policy says, and the purchase-order gate never holds it.
CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_priced_lines(p_quotation_id bigint, p_item_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  pol record;
  v_ids bigint[];
  v_needs_approval boolean;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can confirm lines for purchase';
  END IF;
  SELECT * INTO pol FROM qvm_new_apps.quotation_approval_policy(p_quotation_id);
  -- A line re-issued for a quantity cancelled after confirmation (by the vendor, or by an approved
  -- request) needs nobody's approval again: the part and its price were already signed for. With a
  -- policy that asks for approvals, those are the only lines this confirms.
  v_needs_approval := pol IS NULL OR NOT pol.has_end_customer OR pol.requires_workshop OR pol.requires_customer;
  -- Priced (17), with a wholesale price on the line.
  SELECT COALESCE(array_agg(qi.quotation_item_id), ARRAY[]::bigint[]) INTO v_ids
    FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_id = p_quotation_id
     AND qi.quotation_item_id = ANY(COALESCE(p_item_ids, ARRAY[]::bigint[]))
     AND qi.item_status = 17
     AND COALESCE(qi.price_before_vat, 0) > 0
     AND (NOT v_needs_approval OR qi.reissued_from_item_id IS NOT NULL);
  IF v_needs_approval AND COALESCE(array_length(v_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This customer requires an approval before purchase');
  END IF;
  RETURN jsonb_build_object('status', 'success') || qvm_new_apps.confirm_lines(p_quotation_id, v_ids);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- The signatures the customer's policy asks for, before any purchase. A customer may require the
  -- workshop's confirmation of سعر الجملة, the customer's approval of سعر العميل, both (the default)
  -- or neither — with neither, a priced line may be bought as it is. An order with no end customer
  -- is judged the old way: both signatures, and only once it has been through the approval flow.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_items) e
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
      CROSS JOIN LATERAL qvm_new_apps.quotation_approval_policy(qi.quotation_id) pol
     WHERE qi.reissued_from_item_id IS NULL   -- a line re-issued for a cancelled quantity was approved as its parent
       AND CASE
             WHEN pol.has_end_customer THEN
               (pol.requires_workshop OR pol.requires_customer)
               AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.lines_cleared_for_purchase(qi.quotation_id)))
             ELSE
               EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_rounds r WHERE r.quotation_id = qi.quotation_id)
               AND NOT (COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'workshop'))
                        AND COALESCE(qi.reissued_from_item_id, qi.quotation_item_id) = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'client')))
           END
  ) THEN
    RETURN jsonb_build_object('status', false,
      'message', 'Every line on a purchase order must first be approved by everyone this customer requires');
  END IF;


  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      -- When the buyer took one of the vendor's alternatives instead of the part asked for, the PO is
      -- for the alternative, at the alternative's price. Written here as final_purchase_price so every
      -- reader that already prefers it over the line's cost gets the right number. Left NULL for an
      -- ordinary line, which is exactly what happened before.
      final_purchase_price,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      (SELECT ch.unit_price
         FROM qvm_new_apps.quotation_vendor_items qvi
         JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
        WHERE qvi.cost_id = NULLIF(e->>'cost_id','')::INT),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id, cost_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
    RETURNING ci.confirmed_item_id, ci.quotation_item_id
  ),
  -- Save cost_id back to quotation_items so it can be restored when reopening pricing modal
  cost_id_update AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET cost_id = ii.cost_id, updated_at = NOW()
    FROM inserted_items ii
    JOIN status_update su ON su.confirmed_item_id = ii.confirmed_item_id
    WHERE qi.quotation_item_id = su.quotation_item_id
      AND ii.cost_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id
  JOIN status_update su ON su.confirmed_item_id = pi.confirmed_item_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 40 $$;
