-- A purchase order waits for the line to be confirmed.
--
-- The pricing page raised purchase orders for lines that had not been confirmed yet — New RFQ,
-- Tendering, Added by Vendor, Pending Workshop Approval — because its ranking of statuses knew
-- only some of them, and the server never asked. Now the server asks, in both places a purchase
-- order is created: a line Priced or anything before it is not bought, with one exception the
-- customer's policy grants — a priced line whose customer asks neither the workshop's nor its own
-- approval is bought as it is, as is a line re-issued for a cancelled quantity, which stands on
-- its parent's approvals.

-- The lines among those given that a purchase order may not carry yet, with the status that holds them.
CREATE OR REPLACE FUNCTION qvm_new_apps.lines_not_yet_purchasable(p_quotation_item_ids integer[])
 RETURNS TABLE(quotation_item_id integer, item_status integer, status_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT qi.quotation_item_id, qi.item_status, COALESCE(ld.list_data, qi.item_status::text)
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
    CROSS JOIN LATERAL qvm_new_apps.quotation_approval_policy(qi.quotation_id) pol
   WHERE qi.quotation_item_id = ANY(COALESCE(p_quotation_item_ids, ARRAY[]::integer[]))
     -- The request and its pricing: New RFQ, Extract PN, Ready For Quotation, Sent To Vendor,
     -- Tendering, Added by Vendor, Priced, Pending Workshop Approval.
     AND qi.item_status IN (15, 236, 235, 237, 16, 267, 17, 325)
     AND NOT (
       qi.item_status = 17
       AND (qi.reissued_from_item_id IS NOT NULL
            OR (pol.has_end_customer AND NOT pol.requires_workshop AND NOT pol.requires_customer))
     );
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.lines_not_yet_purchasable(integer[]) TO authenticated;

-- The pricing page's purchase order (the Send PO function calls the qvm_new_apps one; the public
-- copy is kept in step).
CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
  v_blocked integer := 0;
  v_blocked_names text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- A purchase order waits for the line to be confirmed. A line still being requested, priced or
  -- approved — Priced or anything before it — is not bought, with one exception: a priced line
  -- whose customer asks nobody's approval (and a line re-issued for a cancelled quantity, which
  -- stands on its parent's) is bought as it is.
  SELECT count(*), string_agg(DISTINCT b.status_name, ', ')
    INTO v_blocked, v_blocked_names
    FROM qvm_new_apps.lines_not_yet_purchasable(
           (SELECT array_agg(ci.quotation_item_id)
              FROM jsonb_array_elements(p_items) e
              JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT)) b;
  IF v_blocked > 0 THEN
    RETURN jsonb_build_object('status', false,
      'message', format('A purchase order needs confirmed lines: %s selected line(s) still at %s', v_blocked, v_blocked_names));
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

CREATE OR REPLACE FUNCTION public.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
  v_blocked integer := 0;
  v_blocked_names text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- A purchase order waits for the line to be confirmed. A line still being requested, priced or
  -- approved — Priced or anything before it — is not bought, with one exception: a priced line
  -- whose customer asks nobody's approval (and a line re-issued for a cancelled quantity, which
  -- stands on its parent's) is bought as it is.
  SELECT count(*), string_agg(DISTINCT b.status_name, ', ')
    INTO v_blocked, v_blocked_names
    FROM qvm_new_apps.lines_not_yet_purchasable(
           (SELECT array_agg(ci.quotation_item_id)
              FROM jsonb_array_elements(p_items) e
              JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT)) b;
  IF v_blocked > 0 THEN
    RETURN jsonb_build_object('status', false,
      'message', format('A purchase order needs confirmed lines: %s selected line(s) still at %s', v_blocked, v_blocked_names));
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

-- The purchase orders page's purchase order, raised when a supplier invoice is filed.
CREATE OR REPLACE FUNCTION public.upsert_purchase_order_items(p_user_id uuid, p_confirmed_order_id integer, p_confirmed_item_ids integer[], p_mode text DEFAULT 'add'::text, p_uploaded_source text DEFAULT 'internal'::text, p_item_qtys integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_inserted int := 0;
  v_deleted int := 0;
  v_use_qtys boolean := (p_item_qtys IS NOT NULL AND array_length(p_item_qtys,1) = array_length(p_confirmed_item_ids,1));
  v_blocked integer := 0;
  v_blocked_names text;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- The same rule as the pricing page's purchase order: a line Priced or earlier is not bought,
  -- unless it is priced and its customer asks nobody's approval (or it is a re-issued line).
  SELECT count(*), string_agg(DISTINCT b.status_name, ', ')
    INTO v_blocked, v_blocked_names
    FROM qvm_new_apps.lines_not_yet_purchasable(
           (SELECT array_agg(ci.quotation_item_id) FROM qvm_new_apps.confirmed_items ci
             WHERE ci.confirmed_item_id = ANY(p_confirmed_item_ids))) b;
  IF v_blocked > 0 THEN
    RETURN jsonb_build_object('status','error',
      'message', format('A purchase order needs confirmed lines: %s selected line(s) still at %s', v_blocked, v_blocked_names));
  END IF;

  -- Always create a fresh purchase_order to isolate this upload per selection
  INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
  VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
  RETURNING purchase_order_id INTO v_purchase_order_id;

  IF COALESCE(array_length(p_confirmed_item_ids,1),0) > 0 THEN
    IF v_use_qtys THEN
      -- Pair each item id with its allocated units (0 -> NULL, i.e. treat as whole item).
      INSERT INTO purchase_items(confirmed_item_id, purchase_order_id, approved_qty)
      SELECT cid, v_purchase_order_id, NULLIF(qty, 0)
      FROM unnest(p_confirmed_item_ids, p_item_qtys) AS u(cid, qty)
      ON CONFLICT (purchase_order_id, confirmed_item_id) DO NOTHING;
    ELSE
      INSERT INTO purchase_items(confirmed_item_id, purchase_order_id)
      SELECT DISTINCT cid, v_purchase_order_id
      FROM unnest(p_confirmed_item_ids) AS cid
      ON CONFLICT (purchase_order_id, confirmed_item_id) DO NOTHING;
    END IF;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'message','Purchase order items upserted',
    'purchase_order_id', v_purchase_order_id,
    'inserted', v_inserted,
    'deleted', v_deleted
  );
END;
$function$;
