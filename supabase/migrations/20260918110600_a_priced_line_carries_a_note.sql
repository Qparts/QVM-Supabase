-- A priced line can carry a note of its own.
--
-- An alternative has had one since it existed; the line the alternatives hang off did not, which
-- left the vendor with nowhere to say "this is the last one I have" or "price holds to Thursday"
-- about the part actually being quoted.
--
-- A column rather than a row in the notes table. notes carries authorship -- user_id, and a thread
-- per subject -- and the magic-link vendor has no session at all, so every note written from the
-- emailed link would be anonymous, which makes an audit log that cannot audit. What the grid needs
-- is a field the vendor owns and can edit or clear, which is exactly what the alternative's note
-- already is. The notes table keeps doing what it does: the team's threaded commentary, read back
-- as item_notes beside this.

ALTER TABLE qvm_new_apps.quotation_vendor_items
  ADD COLUMN IF NOT EXISTS note text;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[], p_quotation_vendor_id bigint DEFAULT NULL::bigint)
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
                                            'available_brand_id', qvi2.available_brand_id,
                                            'available_brand_name', avail_brand_ld.list_data,
                                            'origin_country_id', qvi2.origin_country_id,
                                            'origin_country_name_en', avail_origin.name_en,
                                            'origin_country_name_ar', avail_origin.name_ar,
                                            'note', qvi2.note,
                                            -- The vendor's alternatives for this line, loaded with
                                            -- the line itself so the البدائل badge has its count on
                                            -- first paint instead of after a second round trip.
                                            'alternatives', qvm_new_apps.alternatives_of_cost(qvi2.cost_id),
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
                                LEFT JOIN qvm_new_apps.list_data avail_brand_ld
                                       ON avail_brand_ld.list_data_id = qvi2.available_brand_id
                                LEFT JOIN qvm_new_apps.origin_countries avail_origin
                                       ON avail_origin.origin_country_id = qvi2.origin_country_id
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

-- 
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
      NULLIF(x->>'available_brand_id','')::bigint               AS available_brand_id,
      NULLIF(x->>'origin_country_id','')::bigint                AS origin_country_id,
      NULLIF(x->>'vendor_item_status','') ::int                AS vendor_item_status,
      NULLIF(x->>'price_source','')                            AS price_source,
      CASE WHEN x ? 'vendor_part_number' THEN x->>'vendor_part_number' ELSE NULL END AS vendor_part_number,
      (x ? 'vendor_part_number')                               AS has_vpn,
      CASE WHEN x ? 'note' THEN x->>'note' ELSE NULL END       AS note,
      (x ? 'note')                                             AS has_note
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
      available_brand_id      = COALESCE(c.available_brand_id, qvi.available_brand_id),
      origin_country_id       = COALESCE(c.origin_country_id, qvi.origin_country_id),
      vendor_item_status      = COALESCE(c.vendor_item_status, qvi.vendor_item_status),
      price_source            = COALESCE(c.price_source, qvi.price_source),
      -- vendor_part_number is set whenever the key is present (allows clearing to empty/NULL).
      vendor_part_number      = CASE WHEN c.has_vpn THEN c.vendor_part_number ELSE qvi.vendor_part_number END,
      -- Same presence test as vendor_part_number, and for the same reason: a note has to be
      -- clearable. COALESCE would make an emptied note mean "leave it alone", so the vendor could
      -- add a note and never take it back.
      note                    = CASE WHEN c.has_note THEN NULLIF(btrim(COALESCE(c.note, '')), '') ELSE qvi.note END,
      best_cost               = FALSE,
      updated_at              = NOW()
    FROM changes c
    WHERE qvi.cost_id = c.cost_id
      AND NOT EXISTS (SELECT 1 FROM locked l WHERE l.cost_id = c.cost_id)
    RETURNING qvi.cost_id, qvi.note, qvi.alternative_part_number, qvi.available_brand_class, qvi.available_quantity,
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
