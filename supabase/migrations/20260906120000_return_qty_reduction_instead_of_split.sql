-- Replace the partial-return ROW SPLIT with quantity reduction + a return log.
--
-- 20260904130000 made an approved partial return split a confirmed_items line into two rows (the
-- returned qty as a new status-29 row, the remainder shrunk in place). That required dropping
-- UNIQUE(quotation_item_id), which broke every ON CONFLICT upsert on the table (fixed in
-- 20260906110000) and, worse, silently changed the cardinality of ~220 joins onto confirmed_items:
-- a plain JOIN ... ON ci.quotation_item_id = qi.quotation_item_id started returning two rows where
-- it had always returned one, double-counting quantities and values in reports with no error.
--
-- Reverting to one row per quotation_item. An approved partial return now just reduces
-- approved_qty on the existing row and records the event in confirmed_item_return_log, so the
-- returned quantity, reason and note survive without a second row existing.

-- 1. The return log ---------------------------------------------------------------------------
-- Deliberately NOT returned_issues / return_items / creditnote_items: those belong to the Returns
-- & Exchanges operational subsystem (upsert_return_case, get_return_exchange_dashboard) and
-- writing approvals into them would show up as cases on that dashboard.

CREATE TABLE IF NOT EXISTS qvm_new_apps.confirmed_item_return_log (
  return_log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  confirmed_item_id integer NOT NULL REFERENCES qvm_new_apps.confirmed_items(confirmed_item_id),
  returned_qty      integer NOT NULL CHECK (returned_qty > 0),
  -- approved_qty left on the line after this return; for a full return the line keeps its
  -- quantity and simply reads Returned(29), so remaining_qty equals returned_qty there.
  remaining_qty     integer NOT NULL,
  is_full_return    boolean NOT NULL DEFAULT false,
  return_reason     integer,
  note_id           integer REFERENCES qvm_new_apps.notes(note_id),
  approved_by       uuid,
  approved_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS confirmed_item_return_log_item_idx
  ON qvm_new_apps.confirmed_item_return_log (confirmed_item_id);

GRANT SELECT, INSERT ON qvm_new_apps.confirmed_item_return_log TO authenticated;

COMMENT ON TABLE qvm_new_apps.confirmed_item_return_log IS
  'One row per approved return (partial or full) against a confirmed item. Append-only: the record
   of what was returned, since an approved partial return now shrinks approved_qty in place rather
   than creating a second confirmed_items row.';

-- Cumulative convenience total, so the common case needs no join to the log.
ALTER TABLE qvm_new_apps.confirmed_items
  ADD COLUMN IF NOT EXISTS returned_qty integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN qvm_new_apps.confirmed_items.returned_qty IS
  'Total quantity returned and approved to date. Sum of confirmed_item_return_log.returned_qty.';

-- 2. Fold any existing split rows back --------------------------------------------------------
-- Written generically (all duplicated quotation_item_ids, not just the one on dev) so it is a
-- no-op wherever the split never ran. For each duplicate group the earliest row is the original;
-- the status-29 siblings are split-offs created by the old approve_item_status_request. The
-- original's approved_qty was already reduced at split time, so it is left alone.

DO $migrate$
DECLARE
  r record;
  v_note_id int;
BEGIN
  FOR r IN
    SELECT dup.confirmed_item_id  AS split_id,
           dup.approved_qty       AS split_qty,
           dup.client_return_reason,
           dup.created_at,
           dup.created_by,
           orig.confirmed_item_id AS orig_id,
           orig.approved_qty      AS orig_qty
    FROM qvm_new_apps.confirmed_items dup
    JOIN LATERAL (
      SELECT c.confirmed_item_id, c.approved_qty
      FROM qvm_new_apps.confirmed_items c
      WHERE c.quotation_item_id = dup.quotation_item_id
      ORDER BY c.confirmed_item_id
      LIMIT 1
    ) orig ON orig.confirmed_item_id <> dup.confirmed_item_id
    WHERE dup.item_status = 29
      AND dup.quotation_item_id IN (
        SELECT quotation_item_id FROM qvm_new_apps.confirmed_items
        GROUP BY quotation_item_id HAVING count(*) > 1)
  LOOP
    -- The split-off row's note followed the returned quantity; bring it back to the surviving row.
    SELECT min(note_id) INTO v_note_id
      FROM qvm_new_apps.notes
     WHERE note_type = 'confirmed_items' AND type_id = r.split_id;

    UPDATE qvm_new_apps.notes
       SET type_id = r.orig_id
     WHERE note_type = 'confirmed_items' AND type_id = r.split_id;

    -- Keep the audit trail: re-pointed, the surviving row reads 28 (requested) -> 29 (approved)
    -- -> prior status (remainder released), which is what actually happened.
    UPDATE qvm_new_apps.status_logs
       SET confirmed_item_id = r.orig_id
     WHERE confirmed_item_id = r.split_id;

    INSERT INTO qvm_new_apps.confirmed_item_return_log
      (confirmed_item_id, returned_qty, remaining_qty, is_full_return, return_reason, note_id,
       approved_by, approved_at)
    VALUES (r.orig_id, r.split_qty, r.orig_qty, false, r.client_return_reason, v_note_id,
            r.created_by, r.created_at);

    UPDATE qvm_new_apps.confirmed_items
       SET returned_qty = returned_qty + r.split_qty
     WHERE confirmed_item_id = r.orig_id;

    -- Delivery paperwork generated for the split row is an artifact of the split: that quantity
    -- was returned, so it should never have had a delivery line of its own.
    DELETE FROM qvm_new_apps.delivery_items WHERE confirmed_item_id = r.split_id;
    DELETE FROM qvm_new_apps.delivery_notes WHERE confirmed_item_id = r.split_id;

    DELETE FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = r.split_id;

    RAISE NOTICE 'folded split row % (qty %) back into %', r.split_id, r.split_qty, r.orig_id;
  END LOOP;
END
$migrate$;

-- 3. Restore the real constraint ---------------------------------------------------------------
-- Back to a plain UNIQUE, so every existing ON CONFLICT (quotation_item_id) and every join onto
-- the table behaves exactly as it did before the split was introduced.

DROP INDEX IF EXISTS qvm_new_apps.confirmed_items_quotation_item_id_active_key;

ALTER TABLE qvm_new_apps.confirmed_items
  DROP CONSTRAINT IF EXISTS confirmed_items_quotation_item_id_key;
ALTER TABLE qvm_new_apps.confirmed_items
  ADD CONSTRAINT confirmed_items_quotation_item_id_key UNIQUE (quotation_item_id);

-- 4. Approval without the split ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(p_confirmed_item_id int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row qvm_new_apps.confirmed_items%ROWTYPE;
  v_approved_qty int;
  v_requested_qty int;
  v_remaining int;
  v_full boolean;
  v_new_status int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_row.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;

  -- Cancellation request -> Canceled, unchanged.
  IF v_row.item_status = 24 THEN
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 18, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, 18, v_uid);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', 18));
  END IF;

  IF v_row.item_status = 28 THEN
    v_approved_qty  := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := LEAST(COALESCE(v_row.requested_return_qty, v_approved_qty), v_approved_qty);

    IF v_requested_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Return quantity must be greater than zero');
    END IF;

    v_full := v_requested_qty >= v_approved_qty;
    -- Full return: the line is entirely returned, so it keeps its quantity and reads Returned(29).
    -- Partial: the quantity still with the customer shrinks and the line goes back to the status
    -- it held before the request.
    v_remaining  := CASE WHEN v_full THEN v_approved_qty ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 29 ELSE COALESCE(v_row.status_before_request, 23) END;

    INSERT INTO qvm_new_apps.confirmed_item_return_log
      (confirmed_item_id, returned_qty, remaining_qty, is_full_return, return_reason, note_id,
       approved_by, approved_at)
    VALUES (p_confirmed_item_id, v_requested_qty, v_remaining, v_full, v_row.client_return_reason,
            v_row.pending_request_note_id, v_uid, now());

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty            = v_remaining,
        returned_qty            = COALESCE(returned_qty, 0) + v_requested_qty,
        item_status             = v_new_status,
        client_return_reason    = CASE WHEN v_full THEN client_return_reason ELSE NULL END,
        requested_return_qty    = NULL,
        status_before_request   = NULL,
        pending_request_note_id = NULL,
        updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, v_new_status, v_uid);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'full_return', v_full,
      'returned_qty', v_requested_qty,
      'remaining_qty', v_remaining
    ));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

-- 5. Drop the ON CONFLICT predicate added by 20260906110000 -------------------------------------
-- With the plain UNIQUE constraint back, the bare column inference works again. Bodies below are
-- the live definitions with " WHERE item_status IS DISTINCT FROM 29" removed.

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
    ON CONFLICT (quotation_item_id)
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
    ON CONFLICT (quotation_item_id) DO UPDATE
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
