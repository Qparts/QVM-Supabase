-- The quoted line's grade and make are the order's, not the vendor's.
--
-- A vendor quoting the requested part is quoting THAT part: its grade (brand_class) and its make
-- (main_brand) were fixed when the order was raised, and the vendor's grid now shows them read-only.
-- Only an alternative — a different part the vendor offers instead — carries a grade and make of the
-- vendor's choosing, on its own row. So a vendor line that arrives without a grade or make takes
-- the item's, which keeps the pricing page's per-vendor data coherent without asking the vendor to
-- restate what the order already said.

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
      -- The line the vendor is quoting IS the requested part: its grade and make are the order's
      -- facts, so they default from the quotation item when the vendor sends none. An alternative
      -- carries its own grade and make on its own row; this never touches those.
      available_brand_class   = COALESCE(c.available_brand_class, qvi.available_brand_class,
                                         (SELECT qi0.brand_class FROM qvm_new_apps.quotation_items qi0 WHERE qi0.quotation_item_id = qvi.quotation_item_id)),
      available_quantity      = COALESCE(c.available_quantity, qvi.available_quantity),
      cost                    = COALESCE(c.cost, qvi.cost),
      sla                     = COALESCE(c.sla, qvi.sla),
      discount_percent        = COALESCE(c.discount_percent, qvi.discount_percent),
      agency_price            = COALESCE(c.agency_price, qvi.agency_price),
      available_brand_id      = COALESCE(c.available_brand_id, qvi.available_brand_id,
                                         (SELECT qi0.main_brand FROM qvm_new_apps.quotation_items qi0 WHERE qi0.quotation_item_id = qvi.quotation_item_id)),
      origin_country_id       = COALESCE(c.origin_country_id, qvi.origin_country_id),
      vendor_item_status      = COALESCE(c.vendor_item_status, qvi.vendor_item_status),
      price_source            = COALESCE(c.price_source, qvi.price_source),
      -- vendor_part_number is set whenever the key is present (allows clearing to empty/NULL).
      vendor_part_number      = CASE WHEN c.has_vpn THEN c.vendor_part_number ELSE qvi.vendor_part_number END,
      -- Same presence test as vendor_part_number, and for the same reason: a note has to be
      -- clearable. COALESCE would make an emptied note mean "leave it alone", so the vendor could
      -- add a note and never take it back.
      note                    = CASE WHEN c.has_note THEN NULLIF(btrim(COALESCE(c.note, '')), '') ELSE qvi.note END,
      -- A new price answers the improvement request. previous_cost stays, so both sides can still
      -- see what the number was before.
      improvement_requested_at = CASE WHEN c.cost IS NOT NULL THEN NULL ELSE qvi.improvement_requested_at END,
      improvement_note         = CASE WHEN c.cost IS NOT NULL THEN NULL ELSE qvi.improvement_note END,
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

  -- A changed price on a line the workshop sent back for a better price answers their request: the
  -- line goes straight back to them as a new request, and they are told. Best-effort — a failure to
  -- reopen must never undo the price that was just saved.
  BEGIN
    PERFORM qvm_new_apps.reopen_workshop_approval_for_changed_price(qvi.quotation_item_id)
       FROM jsonb_array_elements(p_items) AS x
       JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = (x->>'cost_id')::int
      WHERE NULLIF(x->>'cost', '') IS NOT NULL;
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN jsonb_build_object('status', true, 'message', 'Bulk update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0), 'updated', updated,
    'not_found', not_found, 'blocked', blocked);
END;
$function$;
