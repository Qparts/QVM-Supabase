-- Confirming never moves an item backwards.
--
-- confirm_cart_items re-confirmed every item it was handed: an item that already had a confirmed
-- row was overwritten back to Confirmed, on the confirmed row and on the quotation item, even when
-- a purchase order had since been raised on it. Five quotations on QVM/test show exactly that.
--
-- Now an item that already has a confirmed row is set aside and left untouched; only items with
-- no confirmed row are confirmed. The result reports how many were skipped as
-- items_already_confirmed, a list made only of such items returns success with nothing changed,
-- and the status log records only what was actually confirmed.
--
-- Function body is the live one on QVM/test with these changes only.

CREATE OR REPLACE FUNCTION public.confirm_cart_items(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$DECLARE
  v_new_status integer := 19;
  v_items_count integer := 0;
  v_orders_count integer := 0;
  v_updated_count integer := 0;
  v_missing_count integer := 0;
  v_already_count integer := 0;
  v_updated_ids integer[] := '{}';
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (items)');
  END IF;

  WITH input AS (
    SELECT
      NULLIF((elem->>'quotation_id')::text, '')::integer AS quotation_id,
      NULLIF((elem->>'quotation_item_id')::text, '')::integer AS quotation_item_id,
      GREATEST(NULLIF((elem->>'approved_qty')::text, '')::integer, 1) AS approved_qty,
      NULLIF((elem->>'final_brand_class')::text, '')::integer AS final_brand_class
    FROM jsonb_array_elements(p_items) elem
  ),
  validated AS (
    SELECT i.*, qi.quotation_id AS actual_quotation_id
    FROM input i
    LEFT JOIN qvm_new_apps.quotation_items qi
      ON qi.quotation_item_id = i.quotation_item_id
  ),
  missing AS (
    SELECT *
    FROM validated
    WHERE quotation_id IS NULL
       OR quotation_item_id IS NULL
       OR approved_qty IS NULL
       OR actual_quotation_id IS NULL
       OR actual_quotation_id <> quotation_id
  ),
  -- An item that already has a confirmed row is left exactly as it is: whatever happened to it
  -- since (a purchase order, a delivery) must not be undone by confirming its neighbours.
  already AS (
    SELECT DISTINCT v.quotation_item_id
    FROM validated v
    WHERE v.actual_quotation_id = v.quotation_id
      AND EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = v.quotation_item_id)
  ),
  good AS (
    SELECT
      quotation_id,
      quotation_item_id,
      MAX(approved_qty) AS approved_qty,
      MAX(final_brand_class) AS final_brand_class
    FROM validated v
    WHERE actual_quotation_id = quotation_id
      AND NOT EXISTS (SELECT 1 FROM already a WHERE a.quotation_item_id = v.quotation_item_id)
    GROUP BY quotation_id, quotation_item_id
  ),
  order_inputs AS (
    SELECT DISTINCT quotation_id
    FROM good
  ),
  orders AS (
    INSERT INTO qvm_new_apps.confirmed_orders (
      quotation_id,
      created_at,
      updated_at
    )
    SELECT
      quotation_id,
      clock_timestamp(),
      clock_timestamp()
    FROM order_inputs oi
    WHERE NOT EXISTS (
      SELECT 1
      FROM qvm_new_apps.confirmed_orders co
      WHERE co.quotation_id = oi.quotation_id
    )
    RETURNING confirmed_order_id, quotation_id
  ),
  all_orders AS (
    SELECT confirmed_order_id, quotation_id
    FROM orders

    UNION ALL

    SELECT
      co.confirmed_order_id,
      co.quotation_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN order_inputs oi
      ON oi.quotation_id = co.quotation_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM orders o
      WHERE o.quotation_id = co.quotation_id
    )
  ),
  items_ins AS (
    INSERT INTO qvm_new_apps.confirmed_items (
      confirmed_order_id,
      quotation_item_id,
      approved_qty,
      item_status,
      final_part_number,
      final_brand_class,
      created_at,
      updated_at
    )
    SELECT
      o.confirmed_order_id,
      g.quotation_item_id,
      g.approved_qty,
      v_new_status,
      COALESCE(qi.alternative_part_number, qi.part_number),
      COALESCE(g.final_brand_class, qi.brand_class),
      clock_timestamp(),
      clock_timestamp()
    FROM good g
    JOIN all_orders o
      ON o.quotation_id = g.quotation_id
    JOIN qvm_new_apps.quotation_items qi
      ON qi.quotation_item_id = g.quotation_item_id
    ON CONFLICT (quotation_item_id) DO NOTHING
    RETURNING quotation_item_id
  ),
  updated AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET
      item_status = v_new_status,
      updated_at = now()
    WHERE qi.quotation_item_id IN (
      SELECT quotation_item_id
      FROM items_ins
    )
    RETURNING qi.quotation_item_id
  )
  SELECT
    (SELECT COALESCE(count(*), 0)::integer FROM good),
    (SELECT COALESCE(count(*), 0)::integer FROM orders),
    (SELECT COALESCE(count(*), 0)::integer FROM updated),
    (SELECT COALESCE(count(*), 0)::integer FROM missing),
    (SELECT COALESCE(count(*), 0)::integer FROM already),
    (SELECT COALESCE(array_agg(quotation_item_id), '{}') FROM updated)
  INTO
    v_items_count,
    v_orders_count,
    v_updated_count,
    v_missing_count,
    v_already_count,
    v_updated_ids;

  IF v_missing_count > 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'One or more items are invalid or do not belong to the provided quotation_id'
    );
  END IF;

  IF v_updated_count = 0 THEN
    -- Everything in the list was already confirmed: nothing to do, and nothing was touched.
    IF v_already_count > 0 THEN
      RETURN jsonb_build_object(
        'success', true,
        'orders_created', 0,
        'items_confirmed', 0,
        'items_already_confirmed', v_already_count
      );
    END IF;
    RETURN jsonb_build_object(
      'success', false,
      'error', 'No quotation_items were updated'
    );
  END IF;

  INSERT INTO qvm_new_apps.status_logs (
    quotation_item_id,
    item_status,
    status_changed_by
  )
  SELECT
    quotation_item_id,
    v_new_status,
    auth.uid()
  FROM unnest(v_updated_ids) AS s(quotation_item_id);

  RETURN jsonb_build_object(
    'success', true,
    'orders_created', v_orders_count,
    'items_confirmed', v_items_count,
    'items_already_confirmed', v_already_count
  );
END;$function$;
