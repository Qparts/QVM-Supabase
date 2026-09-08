-- The vendor's part number becomes the item's, and their orders show the PO number.
--
-- Until now a vendor writing a part number on their line stored it only on their own row
-- (quotation_vendor_items.vendor_part_number); the shared quotation line kept whatever the client
-- first typed, which on a bare description was usually nothing. It now propagates to
-- quotation_items.part_number, so the number the supplier confirms is the number the order carries.
--
-- Worth knowing: several vendors can be asked to price one line, and each writes to the same field,
-- so the last vendor to save is the number the item keeps. Clearing a vendor's own field changes
-- nothing on the item — only a real number propagates.
--
-- Separately, the supplier's confirmed-orders feeds return po_number ('PO-<id>'), the same name the
-- purchase-order screens use, so both sides of a delivery can refer to it by one label.

CREATE OR REPLACE FUNCTION qvm_new_apps.update_quotation_vendor_items_bulk(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  updated jsonb;
  not_found jsonb;
  blocked jsonb;
BEGIN
  WITH changes AS (
    SELECT
      (x->>'cost_id')::int                                      AS cost_id,
      x->>'alternative_part_number'                             AS alternative_part_number,
      NULLIF(x->>'available_brand_class','')::int               AS available_brand_class,
      NULLIF(x->>'available_quantity','')::int                  AS available_quantity,
      NULLIF(x->>'cost','')::numeric                            AS cost,
      NULLIF(x->>'sla','')                                      AS sla,
      NULLIF(x->>'discount_percent','')::numeric               AS discount_percent,
      NULLIF(x->>'agency_price','')::numeric                   AS agency_price,
      NULLIF(x->>'vendor_item_status','') ::int                AS vendor_item_status,
      NULLIF(x->>'price_source','')                            AS price_source,
      CASE WHEN x ? 'vendor_part_number' THEN x->>'vendor_part_number' ELSE NULL END AS vendor_part_number,
      (x ? 'vendor_part_number')                               AS has_vpn
    FROM jsonb_array_elements(p_items) AS x
  ),
  -- Cancelled(18) / Returned(29) on the quotation line, or a vendor line already stood down.
  locked AS (
    SELECT c.cost_id,
           COALESCE(ld.list_data, 'Cancelled or returned') AS reason
    FROM changes c
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = c.cost_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
    WHERE qi.item_status IN (18, 29)
       OR COALESCE(qvi.vendor_item_status, 0) IN (160, 167)
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_vendor_items qvi
    SET
      alternative_part_number = COALESCE(c.alternative_part_number, qvi.alternative_part_number),
      available_brand_class   = COALESCE(c.available_brand_class, qvi.available_brand_class),
      available_quantity      = COALESCE(c.available_quantity, qvi.available_quantity),
      cost                    = COALESCE(c.cost, qvi.cost),
      sla                     = COALESCE(c.sla, qvi.sla),
      discount_percent        = COALESCE(c.discount_percent, qvi.discount_percent),
      agency_price            = COALESCE(c.agency_price, qvi.agency_price),
      vendor_item_status      = COALESCE(c.vendor_item_status, qvi.vendor_item_status),
      price_source            = COALESCE(c.price_source, qvi.price_source),
      -- vendor_part_number is set whenever the key is present (allows clearing to empty/NULL).
      vendor_part_number      = CASE WHEN c.has_vpn THEN c.vendor_part_number ELSE qvi.vendor_part_number END,
      best_cost               = FALSE,
      updated_at              = NOW()
    FROM changes c
    WHERE qvi.cost_id = c.cost_id
      AND NOT EXISTS (SELECT 1 FROM locked l WHERE l.cost_id = c.cost_id)
    RETURNING qvi.cost_id, qvi.alternative_part_number, qvi.available_brand_class, qvi.available_quantity,
              qvi.cost, qvi.sla, qvi.discount_percent, qvi.agency_price, qvi.vendor_item_status,
              qvi.price_source, qvi.vendor_part_number, qvi.best_cost
  ),
  -- The vendor's part number is now the item's part number. Only a non-empty one propagates:
  -- clearing the vendor's own field means "I have nothing to add", not "wipe the item".
  prop AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET part_number = NULLIF(trim(u.vendor_part_number), ''),
        updated_at  = NOW()
    FROM upd u
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = u.cost_id
    WHERE qi.quotation_item_id = qvi.quotation_item_id
      AND NULLIF(trim(COALESCE(u.vendor_part_number, '')), '') IS NOT NULL
      AND COALESCE(qi.part_number, '') IS DISTINCT FROM trim(u.vendor_part_number)
    RETURNING qi.quotation_item_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(upd.*)), '[]'::jsonb) INTO updated FROM upd;

  SELECT COALESCE(jsonb_agg(to_jsonb(c.*)), '[]'::jsonb) INTO not_found
  FROM (
    SELECT (x->>'cost_id')::int AS cost_id
    FROM jsonb_array_elements(p_items) AS x
    WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_items q WHERE q.cost_id = (x->>'cost_id')::int)
  ) AS c;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('cost_id', b.cost_id, 'reason', b.reason)), '[]'::jsonb)
  INTO blocked
  FROM (
    SELECT qvi.cost_id, COALESCE(ld.list_data, 'Cancelled or returned') AS reason
    FROM jsonb_array_elements(p_items) AS x
    JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = (x->>'cost_id')::int
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
    WHERE qi.item_status IN (18, 29)
       OR COALESCE(qvi.vendor_item_status, 0) IN (160, 167)
  ) b;

  RETURN jsonb_build_object('status', true, 'message', 'Bulk update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0), 'updated', updated,
    'not_found', not_found, 'blocked', blocked);
END;
$function$;

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
                    'po_number', 'PO-' || po.purchase_order_id,
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
                    'total_shipping', (
                        SELECT COALESCE(SUM(pi_sub.vendor_shipping_cost), 0)
                        FROM qvm_new_apps.purchase_items pi_sub
                        WHERE pi_sub.purchase_order_id = po.purchase_order_id
                    ),
                    'total_with_shipping', (
                        SELECT COALESCE(SUM(
                            COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                            + pi_sub.vendor_shipping_cost
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
                            'vendor_shipping_cost', pi.vendor_shipping_cost,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.get_supplier_confirmed_orders(p_vendor_id integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'status', 'success',
        'message', 'Purchase orders fetched successfully',
        'data', COALESCE(json_agg(
            json_build_object(
                'purchase_order_id', po.purchase_order_id,
                'po_number', 'PO-' || po.purchase_order_id,
                'confirmed_order_id', po.confirmed_order_id,
                'quotation_id', co.quotation_id,
                'vendor_status', po.vendor_status,
                'vendor_status_name', vendor_status_ld.list_data,
                'vendor_invoice_url', po.vendor_invoice_url,
                'vendor_invoice_number', po.vendor_invoice_number,
                'vendor_return_url', po.vendor_return_url,
                'uploaded_by', po.uploaded_by,
                'created_at', po.created_at,
                'updated_at', co.updated_at,
                'vendor', json_build_object(
                    'vendor_id', v.vendor_id,
                    'vendor_name', v.vendor_name
                ),
                'quotation', json_build_object(
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'delivery_type_name', dt_ld.list_data,
                    'account_manager', q.account_manager
                ),
                'items', (
                    SELECT json_agg(
                        json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'vin_numbers', (
                                SELECT json_agg(DISTINCT qi.vin)
                                FROM qvm_new_apps.quotation_items qi
                                WHERE qi.quotation_id = q.quotation_id
                            ),
                            'main_brands', (
                                SELECT json_agg(DISTINCT ld.list_data)
                                FROM qvm_new_apps.quotation_items qi2
                                LEFT JOIN qvm_new_apps.list_data ld
                                  ON ld.list_data_id = qi2.main_brand
                                WHERE qi2.quotation_id = q.quotation_id
                            ),
                            'models', (
                                SELECT json_agg(DISTINCT qi3.model)
                                FROM qvm_new_apps.quotation_items qi3
                                WHERE qi3.quotation_id = q.quotation_id
                            ),
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_description', qi_item.part_description,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'approved_qty', pi.approved_qty,
                            'item_status', ci.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'return_type', ci.return_type,
                            'return_type_name', return_type_ld.list_data,
                            'final_purchase_price', COALESCE(
                                NULLIF(pi.final_purchase_price, 0),
                                qvi.cost
                            ),
                            'total_quotation_price', (
                                SELECT COALESCE(SUM(
                                    COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                                ), 0)
                                FROM qvm_new_apps.purchase_items pi_sub
                                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                                  ON pi_sub.cost_id = qvi_sub.cost_id
                                WHERE pi_sub.purchase_order_id = po.purchase_order_id
                            ),
                            'number_of_parts', (
                                SELECT COUNT(*)
                                FROM qvm_new_apps.purchase_items pi2
                                WHERE pi2.purchase_order_id = po.purchase_order_id
                            ),
                            'recieved_qty', pi.received_qty,
                            'vendor_item_status', pi.vendor_item_status
                        )
                    )
                    FROM qvm_new_apps.purchase_items pi
                    JOIN qvm_new_apps.confirmed_items ci 
                      ON pi.confirmed_item_id = ci.confirmed_item_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi
                      ON pi.cost_id = qvi.cost_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld 
                      ON ci.item_status = item_status_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data return_type_ld 
                      ON ci.return_type = return_type_ld.list_data_id
                    LEFT JOIN qvm_new_apps.quotation_items qi_item
                      ON ci.quotation_item_id = qi_item.quotation_item_id
                    WHERE pi.purchase_order_id = po.purchase_order_id
                )
            )
        ), '[]'::json)
    )
    INTO v_result
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.vendors v 
      ON po.vendor_id = v.vendor_id
    JOIN qvm_new_apps.confirmed_orders co 
      ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q 
      ON co.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data vendor_status_ld 
      ON po.vendor_status = vendor_status_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data dt_ld 
      ON q.delivery_type = dt_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data ot_ld 
      ON q.order_type = ot_ld.list_data_id
    WHERE po.vendor_id = p_vendor_id;

    RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION public.get_supplier_confirmed_orders(p_vendor_id integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'status', 'success',
        'message', 'Purchase orders fetched successfully',
        'data', COALESCE(json_agg(
            json_build_object(
                'purchase_order_id', po.purchase_order_id,
                'po_number', 'PO-' || po.purchase_order_id,
                'confirmed_order_id', po.confirmed_order_id,
                'quotation_id', co.quotation_id,
                'vendor_status', po.vendor_status,
                'vendor_status_name', vendor_status_ld.list_data,
                'vendor_invoice_url', po.vendor_invoice_url,
                'vendor_invoice_number', po.vendor_invoice_number,
                'vendor_return_url', po.vendor_return_url,
                'uploaded_by', po.uploaded_by,
                'created_at', po.created_at,
                'updated_at', co.updated_at,
                'vendor', json_build_object(
                    'vendor_id', v.vendor_id,
                    'vendor_name', v.vendor_name
                ),
                'quotation', json_build_object(
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'delivery_type_name', dt_ld.list_data,
                    'account_manager', q.account_manager
                ),
                'items', (
                    SELECT json_agg(
                        json_build_object(
                            'purchase_item_id', pi.purchase_item_id,
                            'vin_numbers', (
                                SELECT json_agg(DISTINCT qi.vin)
                                FROM qvm_new_apps.quotation_items qi
                                WHERE qi.quotation_id = q.quotation_id
                            ),
                            'main_brands', (
                                SELECT json_agg(DISTINCT ld.list_data)
                                FROM qvm_new_apps.quotation_items qi2
                                LEFT JOIN qvm_new_apps.list_data ld
                                  ON ld.list_data_id = qi2.main_brand
                                WHERE qi2.quotation_id = q.quotation_id
                            ),
                            'models', (
                                SELECT json_agg(DISTINCT qi3.model)
                                FROM qvm_new_apps.quotation_items qi3
                                WHERE qi3.quotation_id = q.quotation_id
                            ),
                            'confirmed_item_id', ci.confirmed_item_id,
                            'quotation_item_id', ci.quotation_item_id,
                            'part_description', qi_item.part_description,
                            'part_number', qi_item.part_number,
                            'final_part_number', ci.final_part_number,
                            'approved_qty', pi.approved_qty,
                            'item_status', ci.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'return_type', ci.return_type,
                            'return_type_name', return_type_ld.list_data,
                            'final_purchase_price', COALESCE(
                                NULLIF(pi.final_purchase_price, 0),
                                qvi.cost
                            ),
                            'total_quotation_price', (
                                SELECT COALESCE(SUM(
                                    COALESCE(NULLIF(pi_sub.final_purchase_price, 0), qvi_sub.cost, 0) * pi_sub.approved_qty
                                ), 0)
                                FROM qvm_new_apps.purchase_items pi_sub
                                LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_sub
                                  ON pi_sub.cost_id = qvi_sub.cost_id
                                WHERE pi_sub.purchase_order_id = po.purchase_order_id
                            ),
                            'number_of_parts', (
                                SELECT COUNT(*)
                                FROM qvm_new_apps.purchase_items pi2
                                WHERE pi2.purchase_order_id = po.purchase_order_id
                            ),
                            'recieved_qty', pi.received_qty,
                            'vendor_item_status', pi.vendor_item_status
                        )
                    )
                    FROM qvm_new_apps.purchase_items pi
                    JOIN qvm_new_apps.confirmed_items ci
                      ON pi.confirmed_item_id = ci.confirmed_item_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi
                      ON pi.cost_id = qvi.cost_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld
                      ON ci.item_status = item_status_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data return_type_ld
                      ON ci.return_type = return_type_ld.list_data_id
                    LEFT JOIN qvm_new_apps.quotation_items qi_item
                      ON ci.quotation_item_id = qi_item.quotation_item_id
                    WHERE pi.purchase_order_id = po.purchase_order_id
                )
            )
        ), '[]'::json)
    )
    INTO v_result
    FROM qvm_new_apps.purchase_orders po
    JOIN qvm_new_apps.vendors v
      ON po.vendor_id = v.vendor_id
    JOIN qvm_new_apps.confirmed_orders co
      ON po.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q
      ON co.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data vendor_status_ld
      ON po.vendor_status = vendor_status_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data dt_ld
      ON q.delivery_type = dt_ld.list_data_id
    LEFT JOIN qvm_new_apps.list_data ot_ld
      ON q.order_type = ot_ld.list_data_id
    WHERE po.vendor_id = p_vendor_id;

    RETURN v_result;
END;$function$;
