-- Fix 42P10 regression: dropping confirmed_items' UNIQUE(quotation_item_id) (needed so a partial
-- return could split a line into a second row) broke every upsert that inferred that constraint —
-- confirm_cart_items and insert_confirmed_items both failed with "no unique or exclusion constraint
-- matching the ON CONFLICT specification".
--
-- The invariant the rest of the system actually relies on is "one ACTIVE confirmed_item per
-- quotation_item"; the return split only ever adds rows in the terminal Returned(29) state. So the
-- guarantee is restored as a PARTIAL unique index excluding those, and the two upserts name the
-- matching predicate so Postgres can infer it again.
--
-- IS DISTINCT FROM (not <>) so rows with a NULL item_status stay covered by the index.

CREATE UNIQUE INDEX IF NOT EXISTS confirmed_items_quotation_item_id_active_key
  ON qvm_new_apps.confirmed_items (quotation_item_id)
  WHERE item_status IS DISTINCT FROM 29;

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
  good AS (
    SELECT
      quotation_id,
      quotation_item_id,
      MAX(approved_qty) AS approved_qty,
      MAX(final_brand_class) AS final_brand_class
    FROM validated
    WHERE actual_quotation_id = quotation_id
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
    ON CONFLICT (quotation_item_id) WHERE item_status IS DISTINCT FROM 29
    DO UPDATE SET
      confirmed_order_id = EXCLUDED.confirmed_order_id,
      approved_qty       = EXCLUDED.approved_qty,
      item_status        = EXCLUDED.item_status,
      final_part_number  = EXCLUDED.final_part_number,
      final_brand_class  = EXCLUDED.final_brand_class,
      updated_at         = clock_timestamp()
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
    (SELECT COALESCE(count(*), 0)::integer FROM missing)
  INTO
    v_items_count,
    v_orders_count,
    v_updated_count,
    v_missing_count;

  IF v_missing_count > 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'One or more items are invalid or do not belong to the provided quotation_id'
    );
  END IF;

  IF v_updated_count = 0 THEN
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
  FROM (
    SELECT DISTINCT quotation_item_id
    FROM qvm_new_apps.quotation_items
    WHERE quotation_item_id IN (
      SELECT (elem->>'quotation_item_id')::integer
      FROM jsonb_array_elements(p_items) elem
    )
  ) s;

  RETURN jsonb_build_object(
    'success', true,
    'orders_created', v_orders_count,
    'items_confirmed', v_items_count
  );
END;$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.insert_confirmed_items(p_user_id uuid, p_quotation_item_ids integer[])
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_new_status INT := 19; -- Confirmed
  v_item RECORD;
  v_existing_order RECORD;
  v_confirmed_order_id INT;
  v_final_part_number TEXT;
BEGIN
  IF p_user_id IS NULL OR array_length(p_quotation_item_ids, 1) IS NULL THEN
    RETURN json_build_object(
      'status', 'error',
      'message', 'Missing or invalid input (user_id, quotation_item_ids)'
    );
  END IF;

  FOR v_item IN
    SELECT qi.quotation_item_id,
           qi.quotation_id,
           qi.cost_id,
           qi.part_description,
           qi.part_number,
           qi.alternative_part_number,
           qi.quantity,
           qvi.alternative_part_number AS vendor_alternative
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi
      ON qvi.cost_id = qi.cost_id
    WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
  LOOP
    UPDATE qvm_new_apps.quotation_items
    SET item_status = v_new_status
    WHERE quotation_item_id = v_item.quotation_item_id;

    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
    VALUES (v_item.quotation_item_id, v_new_status, p_user_id);

    SELECT co.confirmed_order_id
    INTO v_existing_order
    FROM qvm_new_apps.confirmed_orders co
    WHERE co.quotation_id = v_item.quotation_id
    LIMIT 1;

    IF v_existing_order.confirmed_order_id IS NOT NULL THEN
      v_confirmed_order_id := v_existing_order.confirmed_order_id;
    ELSE
      INSERT INTO qvm_new_apps.confirmed_orders (quotation_id, created_at, updated_at)
      VALUES (v_item.quotation_id, clock_timestamp(), clock_timestamp())
      RETURNING confirmed_order_id INTO v_confirmed_order_id;
    END IF;

    v_final_part_number := COALESCE(
      v_item.vendor_alternative,
      v_item.alternative_part_number,
      v_item.part_number
    );

    INSERT INTO qvm_new_apps.confirmed_items (
      confirmed_order_id,
      quotation_item_id,
      part_description,
      final_part_number,
      approved_qty,
      item_status,
      created_at,
      updated_at
    )
    VALUES (
      v_confirmed_order_id,
      v_item.quotation_item_id,
      v_item.part_description,
      v_final_part_number,
      v_item.quantity,
      v_new_status,
      clock_timestamp(),
      clock_timestamp()
    )
    ON CONFLICT (quotation_item_id) WHERE item_status IS DISTINCT FROM 29 DO UPDATE
     SET
     confirmed_order_id = EXCLUDED.confirmed_order_id,
     part_description   = EXCLUDED.part_description,
     final_part_number  = EXCLUDED.final_part_number,
     approved_qty       = EXCLUDED.approved_qty,
     item_status        = EXCLUDED.item_status,
     updated_at         = clock_timestamp();
  END LOOP;

  RETURN json_build_object(
    'status', 'success',
    'message', 'Quotation items updated successfully',
    'updated_items', p_quotation_item_ids
  );
END;
$function$;

