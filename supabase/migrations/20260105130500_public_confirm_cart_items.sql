CREATE OR REPLACE FUNCTION public.confirm_cart_items(
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, qvm_new_apps
AS $$
DECLARE
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
      GREATEST(NULLIF((elem->>'approved_qty')::text, '')::integer, 1) AS approved_qty
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
    SELECT quotation_id, quotation_item_id, approved_qty
    FROM validated
    WHERE actual_quotation_id = quotation_id
  ),
  orders AS (
    INSERT INTO qvm_new_apps.confirmed_orders (quotation_id)
    SELECT DISTINCT quotation_id
    FROM good
    RETURNING confirmed_order_id, quotation_id
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
      qi.brand_class,
      now(),
      now()
    FROM good g
    JOIN orders o ON o.quotation_id = g.quotation_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = g.quotation_item_id
    RETURNING quotation_item_id
  ),
  updated AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET item_status = v_new_status,
        updated_at = now()
    WHERE qi.quotation_item_id IN (SELECT quotation_item_id FROM items_ins)
    RETURNING qi.quotation_item_id
  )
  SELECT
    (SELECT COALESCE(count(*), 0)::integer FROM good),
    (SELECT COALESCE(count(*), 0)::integer FROM orders),
    (SELECT COALESCE(count(*), 0)::integer FROM updated),
    (SELECT COALESCE(count(*), 0)::integer FROM missing)
  INTO v_items_count, v_orders_count, v_updated_count, v_missing_count;

  IF v_missing_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'One or more items are invalid or do not belong to the provided quotation_id');
  END IF;

  IF v_updated_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No quotation_items were updated');
  END IF;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
  SELECT quotation_item_id, v_new_status, auth.uid()
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
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_cart_items(jsonb) TO authenticated;
