-- Bug: when the same admin vendor is sent the same RFQ under two different vendor branches,
-- qvm_new_apps.quotation_vendors correctly creates two distinct rows (one per
-- (quotation_id, vendor_id, vendor_branch_id)), but the list/detail read paths merged them back
-- into a single logical "vendor quotation" whenever the caller didn't pass a specific branch
-- filter (p_vendor_branch_ids IS NULL) -- which is exactly the admin vendor's default "All
-- branches" view. That merge (introduced in 20260707141354_vendor_quotations_list_aggregate_by_quotation.sql)
-- made vendor1-branch and vendor2-branch appear as the same row in the list, and
-- get_vendor_quotation_details folded both branches' quotation_vendor_items into one
-- vendor_pricing[] array per item -- the frontend picks vendor_pricing[0], so editing the cost
-- from either branch's screen updated whichever row happened to sort first, visible from both.
--
-- Fix: stop merging by quotation_id. Each quotation_vendor_id is its own independent "vendor
-- quotation" and must always be listed/read as such, never grouped with a sibling branch's row.
-- The list RPC now emits one row per quotation_vendor_id (matching its pre-141354 behavior, kept
-- with the priced_parts field added since). The detail RPC gains an optional
-- p_quotation_vendor_id that -- when supplied -- pins the fetch to that exact row, sidestepping
-- any ambiguity from the header branch-filter state; branch-id filtering remains as a fallback
-- for callers (like the magic-link token path) that don't have a specific quotation_vendor_id.

DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_quotations(bigint, integer, integer, text, bigint[]);

CREATE FUNCTION qvm_new_apps.get_vendor_quotations(p_vendor_id bigint, p_page integer DEFAULT 1, p_page_size integer DEFAULT 100, p_order_number text DEFAULT NULL::text, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
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
        'priced_parts', (
          SELECT COUNT(*)
          FROM qvm_new_apps.quotation_vendor_items qvi3
          WHERE qvi3.quotation_vendor_id = p.quotation_vendor_id
            AND qvi3.cost IS NOT NULL AND qvi3.cost > 0
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

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_quotations(bigint, integer, integer, text, bigint[]) TO anon, authenticated, service_role;

DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_quotation_details(integer, integer, bigint[]);

CREATE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[], p_quotation_vendor_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_ids BIGINT[];
    v_vendor_status INT;
BEGIN
    IF p_quotation_vendor_id IS NOT NULL THEN
      -- Precise, unambiguous scope: exactly the row the caller clicked into. Still verify it
      -- actually belongs to this vendor/quotation so a stale/foreign id can't leak data.
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND qv.quotation_vendor_id = p_quotation_vendor_id;
    ELSE
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids));
    END IF;

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_ids[1],
            'vendor_status', v_vendor_status,
            'vendor_name', (SELECT v.vendor_name FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_vendor_id),
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
                SELECT json_agg(t.obj)
                FROM (
                    SELECT DISTINCT ON (qi.quotation_item_id)
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
                                  AND qvi2.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                            )
                        ) AS obj
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
                      AND qvi.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                    ORDER BY qi.quotation_item_id
                ) t
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_quotation_details(integer, integer, bigint[], bigint) TO anon, authenticated, service_role;

-- get_vendor_quotation_by_token resolves its own single-branch array from the token's row and
-- doesn't have a quotation_vendor_id to pass -- CREATE OR REPLACE is enough since its signature
-- (p_token uuid) is unchanged; only re-pointing it at the new 4-arg get_vendor_quotation_details
-- overload (explicit NULL for p_quotation_vendor_id) so it keeps resolving correctly.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_quotation_id integer;
  v_vendor_id integer;
  v_vendor_branch_id bigint;
  v_expires_at timestamptz;
BEGIN
  SELECT qv.quotation_id, qv.vendor_id, qv.vendor_branch_id, qv.token_expires_at
  INTO v_quotation_id, v_vendor_id, v_vendor_branch_id, v_expires_at
  FROM qvm_new_apps.quotation_vendors qv
  WHERE qv.access_token = p_token;

  IF v_quotation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF now() > v_expires_at THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  RETURN qvm_new_apps.get_vendor_quotation_details(
    v_quotation_id,
    v_vendor_id,
    CASE WHEN v_vendor_branch_id IS NULL THEN NULL ELSE ARRAY[v_vendor_branch_id] END,
    NULL
  );
END;
$function$;

-- Dead old overloads that predate the branch model entirely (no p_vendor_branch_ids param at
-- all) -- confirmed unused: the frontend always calls with the 5-arg/4-arg signatures above, so
-- these can only ever be reached by a caller that doesn't know about branches yet, which would
-- silently reintroduce the exact leak this migration fixes.
DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_quotations(bigint);
DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_quotations(bigint, integer, integer, text);
DROP FUNCTION IF EXISTS qvm_new_apps.get_vendor_quotation_details(integer, integer);
