-- Synced from QVM/test branch applied migration history (version 20260706144713, name: vendor_branch_scoped_rfq_routing_phase2)
-- Vendor multi-branch (Phase 2): branch-scoped RFQ routing.
-- Adds vendor_branch_id to quotation_vendors/purchase_orders and threads it through
-- the RFQ-send -> vendor-read -> purchase-order pipeline so a vendor user only sees
-- quotations/orders assigned to their branch(es); admin-vendor keeps whole-account view.
-- Legacy/no-branch vendors are unaffected: vendor_branch_id stays NULL end-to-end and
-- no branch filter is ever applied when the caller passes p_vendor_branch_ids = NULL.

-- 1. Schema ---------------------------------------------------------------------------------

ALTER TABLE qvm_new_apps.quotation_vendors
  ADD COLUMN vendor_branch_id bigint REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id);

ALTER TABLE qvm_new_apps.purchase_orders
  ADD COLUMN vendor_branch_id bigint REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id);

-- 2. create_vendors_quotations: vendor_ids[] -> vendor_selections jsonb [{vendor_id, vendor_branch_id}] --

DROP FUNCTION IF EXISTS qvm_new_apps.create_vendors_quotations(bigint[], bigint, jsonb);
DROP FUNCTION IF EXISTS public.create_vendors_quotations(bigint[], bigint, jsonb);

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendors_quotations(p_vendor_selections jsonb, p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_selection           JSONB;
  v_vendor_id           BIGINT;
  v_vendor_branch_id    BIGINT;
  v_quotation_vendor_id BIGINT;
  v_results             JSONB := '[]'::jsonb;
  rec                   JSONB;
  v_item_id             BIGINT;
  v_cost                NUMERIC;
  v_from_database       BOOLEAN;
  v_discount            NUMERIC;
  v_vendor_item_status  INTEGER;
  v_new_cost_id         BIGINT;
BEGIN
  IF p_vendor_selections IS NULL OR jsonb_typeof(p_vendor_selections) <> 'array' OR jsonb_array_length(p_vendor_selections) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_vendor_selections must be a non-empty JSON array');
  END IF;

  IF p_quotation_items IS NULL OR jsonb_typeof(p_quotation_items) <> 'array' OR jsonb_array_length(p_quotation_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_quotation_items must be a non-empty JSON array');
  END IF;

  FOR v_selection IN SELECT * FROM jsonb_array_elements(p_vendor_selections) LOOP
    v_vendor_id        := (v_selection->>'vendor_id')::BIGINT;
    v_vendor_branch_id := NULLIF(v_selection->>'vendor_branch_id', '')::BIGINT;

    SELECT quotation_vendor_id
    INTO v_quotation_vendor_id
    FROM qvm_new_apps.quotation_vendors
    WHERE vendor_id = v_vendor_id
      AND quotation_id = p_quotation_id
      AND vendor_branch_id IS NOT DISTINCT FROM v_vendor_branch_id
    LIMIT 1;

    IF v_quotation_vendor_id IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, vendor_branch_id, quotation_id, created_at)
      VALUES (v_vendor_id, v_vendor_branch_id, p_quotation_id, NOW())
      RETURNING quotation_vendor_id INTO v_quotation_vendor_id;
    END IF;

    -- Replace: delete old items for this vendor so only newly selected items remain
    DELETE FROM qvm_new_apps.quotation_vendor_items
    WHERE vendor_id = v_vendor_id
      AND quotation_vendor_id = v_quotation_vendor_id;

    FOR rec IN SELECT * FROM jsonb_array_elements(p_quotation_items) LOOP
      v_item_id            := (rec->>'quotation_item_id')::BIGINT;
      v_cost               := NULLIF(rec->>'cost','')::NUMERIC;
      v_discount           := NULLIF(rec->>'discount_percent','')::NUMERIC;
      v_from_database      := (rec->>'from_database')::BOOLEAN;
      v_vendor_item_status := (rec->>'vendor_item_status')::INTEGER;

      INSERT INTO qvm_new_apps.quotation_vendor_items (
        quotation_item_id, vendor_id, quotation_vendor_id,
        best_cost, cost, discount_percent, from_database,
        vendor_item_status, created_at, updated_at
      )
      VALUES (
        v_item_id, v_vendor_id, v_quotation_vendor_id,
        FALSE, v_cost, v_discount, v_from_database,
        v_vendor_item_status, NOW(), NOW()
      )
      ON CONFLICT (quotation_item_id, vendor_id) DO UPDATE
      SET cost = EXCLUDED.cost,
          discount_percent = EXCLUDED.discount_percent,
          from_database = EXCLUDED.from_database,
          vendor_item_status = EXCLUDED.vendor_item_status,
          updated_at = NOW()
      RETURNING cost_id INTO v_new_cost_id;

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'quotation_vendor_id', v_quotation_vendor_id,
          'vendor_id', v_vendor_id,
          'vendor_branch_id', v_vendor_branch_id,
          'quotation_id', p_quotation_id,
          'quotation_item_id', v_item_id,
          'cost_id', v_new_cost_id,
          'inserted', v_new_cost_id IS NOT NULL
        )
      );

    END LOOP;

  END LOOP;

  -- Update selected quotation items status to "Sent To Vendor"
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  )
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 237,
      updated_at = now()
  FROM sent_items si
  WHERE qi.quotation_item_id = si.quotation_item_id;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT (log_rec->>'quotation_item_id')::bigint, 237, auth.uid(), now()
  FROM jsonb_array_elements(p_quotation_items) log_rec
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_vendors_quotations(p_vendor_selections jsonb, p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$
BEGIN
    RETURN qvm_new_apps.create_vendors_quotations(
        p_vendor_selections,
        p_quotation_id,
        p_quotation_items
    );
END;
$function$;

-- 3. get_vendor_quotations: optional branch filter -------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotations(p_vendor_id bigint, p_page integer DEFAULT 1, p_page_size integer DEFAULT 100, p_order_number text DEFAULT NULL::text, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
  result JSON;
  offset_val INT;
BEGIN
  offset_val := GREATEST((p_page - 1) * p_page_size, 0);

  WITH base AS (
    SELECT
      qv.quotation_vendor_id,
      qv.vendor_status,
      qv.vendor_branch_id,
      qv.created_at,
      q.quotation_id,
      q.order_number
    FROM qvm_new_apps.quotation_vendors qv
    JOIN qvm_new_apps.quotations q ON qv.quotation_id = q.quotation_id
    WHERE qv.vendor_id = p_vendor_id::INT
      AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
      AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids))
  ),
  total AS (
    SELECT COUNT(*) AS cnt FROM base
  ),
  paginated AS (
    SELECT *
    FROM base
    ORDER BY created_at DESC
    LIMIT p_page_size
    OFFSET offset_val
  )
  SELECT json_build_object(
    'status', 'success',
    'message', 'Vendor quotations fetched successfully',
    'total_count', (SELECT cnt FROM total),
    'data', COALESCE(json_agg(
      json_build_object(
        'quotation_vendor_id', p.quotation_vendor_id,
        'quotation_id', p.quotation_id,
        'date_sent', p.created_at,
        'order_number', p.order_number,
        'vendor_status', p.vendor_status,
        'vendor_branch_id', p.vendor_branch_id,
        'vin_numbers', (
          SELECT json_agg(DISTINCT qi.vin)
          FROM qvm_new_apps.quotation_items qi
          WHERE qi.quotation_id = p.quotation_id
        ),
        'main_brands', (
          SELECT json_agg(DISTINCT ld.list_data)
          FROM qvm_new_apps.quotation_items qi2
          LEFT JOIN qvm_new_apps.list_data ld
            ON ld.list_data_id = qi2.main_brand
          WHERE qi2.quotation_id = p.quotation_id
        ),
        'models', (
          SELECT json_agg(DISTINCT qi3.model)
          FROM qvm_new_apps.quotation_items qi3
          WHERE qi3.quotation_id = p.quotation_id
        ),
        'total_quotation_price', (
          SELECT COALESCE(SUM(qvi.cost), 0)
          FROM qvm_new_apps.quotation_vendor_items qvi
          WHERE qvi.quotation_vendor_id = p.quotation_vendor_id
        ),
        'number_of_parts', (
          SELECT COUNT(*)
          FROM qvm_new_apps.quotation_vendor_items qvi2
          WHERE qvi2.quotation_vendor_id = p.quotation_vendor_id
        ),
        'order_notes', (
          SELECT json_agg(
            json_build_object(
              'note_description', n.note_description,
              'note_attachment', n.note_attachment,
              'created_at', n.created_at,
              'user_name', u.user_name
            )
            ORDER BY n.created_at DESC
          )
          FROM qvm_new_apps.notes n
          LEFT JOIN qvm_new_apps.user_data u
            ON u.user_id = n.user_id
          WHERE n.note_type = 'quotation_vendor'
            AND n.type_id = p.quotation_vendor_id
            AND n.is_internal = FALSE
        )
      )
      ORDER BY p.created_at DESC
    ), '[]'::JSON)
  )
  INTO result
  FROM paginated p;

  RETURN result;
END;
$function$;

-- 4. get_vendor_quotation_details: optional branch filter ------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_id BIGINT;
    v_vendor_status INT;
BEGIN
    SELECT qv.quotation_vendor_id, qv.vendor_status
    INTO v_quotation_vendor_id, v_vendor_status
    FROM qvm_new_apps.quotation_vendors qv
    WHERE qv.quotation_id = p_quotation_id
      AND qv.vendor_id = p_vendor_id
      AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids))
    LIMIT 1;

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_id,
            'vendor_status', v_vendor_status,
            'quotation', (
                SELECT jsonb_build_object(
                    'quotation_id', q.quotation_id,
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'account_manager', q.account_manager,
                    'created_at', q.created_at,
                    'updated_at', q.updated_at
                )
                FROM qvm_new_apps.quotations q
                WHERE q.quotation_id = p_quotation_id
            ),
            'items', (
                SELECT json_agg(
                    json_build_object(
                        'quotation_item_id', qi.quotation_item_id,
                        'vin', qi.vin,
                        'main_brand', qi.main_brand,
                        'main_brand_name', main_brand_ld.list_data,
                        'model', qi.model,
                        'part_description', qi.part_description,
                        'part_number', qi.part_number,
                        'quantity', qi.quantity,
                        'brand_class', qi.brand_class,
                        'brand_class_name', brand_class_ld.list_data,
                        'part_category', qi.part_category,
                        'part_category_name', part_category_ld.list_data,
                        'part_photo', qi.part_photo,
                        'item_status', qi.item_status,
                        'item_status_name', item_status_ld.list_data,
                        'alternative_part_number', qi.alternative_part_number,
                        'created_at', qi.created_at,
                        'updated_at', qi.updated_at,
                        'vendor_pricing', (
                            SELECT COALESCE(
                                json_agg(
                                    json_build_object(
                                        'cost_id', qvi2.cost_id,
                                        'cost', qvi2.cost,
                                        'vendor_id', qvi2.vendor_id,
                                        'vendor_item_status', qvi2.vendor_item_status,
                                        'discount_percent', qvi2.discount_percent,
                                        'agency_price', qvi2.agency_price,
                                        'sla', qvi2.sla,
                                        'best_cost', qvi2.best_cost,
                                        'available_quantity', qvi2.available_quantity,
                                        'quotation_vendor_id', qvi2.quotation_vendor_id,
                                        'available_brand_class', qvi2.available_brand_class,
                                        'alternative_part_number', qvi2.alternative_part_number,
                                        'created_at', qvi2.created_at,
                                        'updated_at', qvi2.updated_at,
                                        'item_notes', (
                                            SELECT json_agg(
                                                json_build_object(
                                                    'note_description', n.note_description,
                                                    'note_attachment', n.note_attachment,
                                                    'created_at', n.created_at,
                                                    'user_name', u.user_name
                                                )
                                                ORDER BY n.created_at DESC
                                            )
                                            FROM qvm_new_apps.notes n
                                            LEFT JOIN qvm_new_apps.user_data u
                                              ON u.user_id = n.user_id
                                            WHERE n.note_type = 'quotation_vendor_item'
                                              AND n.type_id = qvi2.cost_id
                                              AND n.is_internal = FALSE
                                        )
                                    )
                                ),
                                '[]'::json
                            )
                            FROM qvm_new_apps.quotation_vendor_items qvi2
                            WHERE qvi2.quotation_item_id = qi.quotation_item_id
                              AND qvi2.vendor_id = p_vendor_id
                        )
                    )
                )
                FROM qvm_new_apps.quotation_vendor_items qvi
                JOIN qvm_new_apps.quotation_items qi
                  ON qi.quotation_item_id = qvi.quotation_item_id
                LEFT JOIN qvm_new_apps.list_data main_brand_ld
                       ON qi.main_brand = main_brand_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data brand_class_ld
                       ON qi.brand_class = brand_class_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data part_category_ld
                       ON qi.part_category = part_category_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data item_status_ld
                       ON qi.item_status = item_status_ld.list_data_id
                WHERE qvi.vendor_id = p_vendor_id
                  AND qvi.quotation_vendor_id = v_quotation_vendor_id
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

-- 5. get_supplier_confirmed_orders_paged: optional branch filter ------------------------------

CREATE OR REPLACE FUNCTION public.get_supplier_confirmed_orders_paged(p_vendor_id integer, p_order_number text DEFAULT NULL::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_result JSON;
    v_offset integer := (p_page - 1) * p_page_size;
    v_total integer;
BEGIN
    SELECT COUNT(DISTINCT po.purchase_order_id)
    INTO v_total
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
    WHERE po.vendor_id = p_vendor_id
      AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
      AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids));

    SELECT json_build_object(
        'status', 'success',
        'total', v_total,
        'page', p_page,
        'page_size', p_page_size,
        'data', COALESCE((
            SELECT json_agg(po_row)
            FROM (
                SELECT json_build_object(
                    'purchase_order_id', po.purchase_order_id,
                    'confirmed_order_id', po.confirmed_order_id,
                    'quotation_id', co.quotation_id,
                    'vendor_status', po.vendor_status,
                    'vendor_status_name', vendor_status_ld.list_data,
                    'vendor_invoice_url', po.vendor_invoice_url,
                    'vendor_invoice_number', po.vendor_invoice_number,
                    'created_at', po.created_at,
                    'vendor', json_build_object(
                        'vendor_id', v.vendor_id,
                        'vendor_name', v.vendor_name
                    ),
                    'quotation', json_build_object(
                        'order_number', q.order_number,
                        'plate_number', q.plate_number,
                        'delivery_type_name', dt_ld.list_data,
                        'account_manager', q.account_manager
                    ),
                    'total_price', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                        ), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                          ON pi_sub.cost_id = qvi_sub.cost_id
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_qty', (
                        SELECT COALESCE(SUM(pi_sub.approved_qty), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'items', (
                        SELECT json_agg(json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'part_description', qi_item.part_description,
                            'approved_qty', pi.approved_qty,
                            'unit_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost),
                            'total_cost', COALESCE(NULLIF(pi.final_purchase_price, 0), qvi.cost, 0) * pi.approved_qty,
                            'item_status_name', item_status_ld.list_data,
                            'vendor_item_status', pi.vendor_item_status
                        ))
                        FROM qvm_new_apps.purchase_items pi
                        JOIN qvm_new_apps.confirmed_items ci ON pi.confirmed_item_id = ci.confirmed_item_id
                        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON pi.cost_id = qvi.cost_id
                        LEFT JOIN qvm_new_apps.list_data item_status_ld ON ci.item_status = item_status_ld.list_data_id
                        LEFT JOIN qvm_new_apps.quotation_items qi_item ON ci.quotation_item_id = qi_item.quotation_item_id
                        WHERE pi.purchase_order_id = po.purchase_order_id
                    )
                ) AS po_row
                FROM qvm_new_apps.purchase_orders po
                JOIN qvm_new_apps.vendors v ON po.vendor_id = v.vendor_id
                JOIN qvm_new_apps.confirmed_orders co ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
                LEFT JOIN qvm_new_apps.list_data vendor_status_ld ON po.vendor_status = vendor_status_ld.list_data_id
                LEFT JOIN qvm_new_apps.list_data dt_ld ON q.delivery_type = dt_ld.list_data_id
                WHERE po.vendor_id = p_vendor_id
                  AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
                  AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids))
                ORDER BY po.created_at DESC
                LIMIT p_page_size OFFSET v_offset
            ) sub
        ), '[]'::json)
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

-- 6. get_supplier_status_bar: optional branch filter -------------------------------------------

CREATE OR REPLACE FUNCTION public.get_supplier_status_bar(p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'status', 'success',
        'message', 'Supplier status bar counts retrieved successfully',
        'data', json_build_object(
            -- 1. RFQs not confirmed yet
            'new_rfqs',
            (
                SELECT COUNT(*)
                FROM qvm_new_apps.quotations q
                JOIN qvm_new_apps.quotation_vendors qv
                  ON q.quotation_id = qv.quotation_id
                WHERE qv.vendor_id = p_vendor_id
                  AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids))
                  AND NOT EXISTS (
                      SELECT 1
                      FROM qvm_new_apps.confirmed_orders co
                      WHERE co.quotation_id = q.quotation_id
                  )
            ),
            -- 2. Confirmed Orders for this supplier
            'confirmed_orders',
            (
                SELECT COUNT(*)
                FROM qvm_new_apps.confirmed_orders co
                JOIN qvm_new_apps.quotation_vendors qv
                  ON co.quotation_id = qv.quotation_id
                WHERE qv.vendor_id = p_vendor_id
                  AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids))
            ),
            -- 3. Pending Purchase Orders (no invoice yet)
            'pending_purchase_orders',
            (
                SELECT COUNT(*)
                FROM qvm_new_apps.purchase_orders po
                JOIN qvm_new_apps.confirmed_orders co
                  ON po.confirmed_order_id = co.confirmed_order_id
                JOIN qvm_new_apps.quotation_vendors qv
                  ON co.quotation_id = qv.quotation_id
                WHERE qv.vendor_id = p_vendor_id
                  AND po.vendor_invoice_url IS NULL
                  AND (p_vendor_branch_ids IS NULL OR po.vendor_branch_id = ANY(p_vendor_branch_ids))
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;$function$;

-- 7. create_purchase_orders_anditems: propagate vendor_branch_id onto purchase_orders ---------

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
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
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
;
