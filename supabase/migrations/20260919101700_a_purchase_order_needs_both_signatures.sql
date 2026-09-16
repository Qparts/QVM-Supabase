-- A purchase order needs both signatures.
--
-- The workshop confirms سعر الجملة; the customer approves سعر العميل; only then is a line bought.
-- create_purchase_orders_anditems now refuses a purchase order carrying any line that lacks either —
-- for orders that have been through the approval flow. An order with no approval rounds at all
-- predates the flow, and refusing those would stop every legacy purchase, so it is left as it was.
-- The pricing page says the same thing on its button before the call is ever made.

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

  -- Both signatures before any purchase. A line the workshop confirmed at سعر الجملة AND the customer
  -- approved at سعر العميل may go on a purchase order; one without either may not. Applied only to
  -- orders that have been through the approval flow at all — an order with no rounds predates it,
  -- and refusing those would stop every legacy purchase in the building.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_items) e
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
     WHERE EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_rounds r WHERE r.quotation_id = qi.quotation_id)
       AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'workshop'))
                AND qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'client')))
  ) THEN
    RETURN jsonb_build_object('status', false,
      'message', 'Every line on a purchase order must be confirmed by the workshop and approved by the customer first');
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

CREATE OR REPLACE FUNCTION public.create_purchase_orders_anditems(p_items jsonb)
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

  -- Both signatures before any purchase. A line the workshop confirmed at سعر الجملة AND the customer
  -- approved at سعر العميل may go on a purchase order; one without either may not. Applied only to
  -- orders that have been through the approval flow at all — an order with no rounds predates it,
  -- and refusing those would stop every legacy purchase in the building.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_items) e
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
     WHERE EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_rounds r WHERE r.quotation_id = qi.quotation_id)
       AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'workshop'))
                AND qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'client')))
  ) THEN
    RETURN jsonb_build_object('status', false,
      'message', 'Every line on a purchase order must be confirmed by the workshop and approved by the customer first');
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
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
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
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;
