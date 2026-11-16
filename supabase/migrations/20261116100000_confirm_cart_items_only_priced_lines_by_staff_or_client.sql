-- confirm_cart_items: only Priced lines with a selling price, and only by Qparts staff or the client.
--
-- It confirmed whatever it was handed: on QVM/test about 400 lines went to Confirmed straight from
-- Extract PN or Sent To Vendor (327 of them still without a selling price), all through the REST
-- API as Qparts Admin, none of them from a screen (the RFQs cart only offers Priced lines). Any
-- signed-in user could call it, vendors included.
--
-- Now every line not already confirmed has to be Priced (17) with a selling price above zero, or
-- the whole list is refused before anything is written, naming each line and why. The caller has
-- to be Qparts staff (user_type 185) or a client (183) confirming lines of their own branch, or of
-- their company's branches for a Client Admin.
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
  v_user_type integer;
  v_user_role integer;
  v_user_company integer;
  v_user_branch integer;
  v_not_ready text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (items)');
  END IF;

  -- Who may confirm: Qparts staff, or the client the order belongs to (a Client Admin across the
  -- company's branches, anyone else on their own branch: the same reach the RFQs dashboard gives
  -- them). Vendors and anyone else may not.
  SELECT ud.user_type, ud.user_role, ud.user_company, ud.user_branch
  INTO v_user_type, v_user_role, v_user_company, v_user_branch
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_id = auth.uid();

  IF v_user_type IS DISTINCT FROM 185 AND v_user_type IS DISTINCT FROM 183 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only Qparts staff or the client can confirm items');
  END IF;

  IF v_user_type = 183 AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) e
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = NULLIF((e->>'quotation_item_id')::text, '')::integer
    -- COALESCE: a user with no branch (NULL) reaches no line, rather than slipping through as NULL.
    WHERE NOT COALESCE(
      (v_user_role = 170 AND EXISTS (
        SELECT 1 FROM qvm_new_apps.client_branches cb
        WHERE cb.list_data_id = v_user_company AND cb.customer_id = qi.customer_id))
      OR (v_user_role IS DISTINCT FROM 170 AND qi.customer_id = v_user_branch),
      false)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You can only confirm items of your own branch');
  END IF;

  -- What may be confirmed: a Priced line with a selling price. A line already confirmed is left as
  -- it is further down, so it isn't held against the rest. One line that isn't ready refuses the
  -- whole list, before anything is written.
  SELECT string_agg(DISTINCT
           COALESCE(NULLIF(btrim(qi.part_description), ''), NULLIF(btrim(qi.part_number), ''), 'item ' || qi.quotation_item_id)
           || ' (' || CASE WHEN qi.item_status = 17 THEN 'no selling price'
                           ELSE COALESCE(ld.list_data, 'status ' || qi.item_status) END || ')', ', ')
  INTO v_not_ready
  FROM jsonb_array_elements(p_items) e
  JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = NULLIF((e->>'quotation_item_id')::text, '')::integer
  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = qi.quotation_item_id)
    AND (qi.item_status IS DISTINCT FROM 17 OR COALESCE(qi.price_before_vat, 0) <= 0);

  IF v_not_ready IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Only priced items with a selling price can be confirmed. Not ready: ' || v_not_ready
    );
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

notify pgrst, 'reload schema';
