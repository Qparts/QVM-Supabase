-- Genuine means genuine.
--
-- A genuine part's origin is the marque, not a factory address. The grid already set the origin to
-- Genuine when a Genuine grade was picked, but only as a default the vendor could change back. Now
-- it is a rule, on the quoted line and on every alternative, and it holds in the database as well
-- as on the screen: a Genuine grade forces the Genuine origin whatever the client sent, and any other
-- grade leaves the country to the vendor.

-- Is this brand_class row the Genuine one? By name, because the id is minted per environment.
CREATE OR REPLACE FUNCTION qvm_new_apps.is_genuine_class(p_brand_class bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld
                  WHERE ld.list_data_id = p_brand_class AND lower(btrim(ld.list_data)) = 'genuine');
$function$;

-- The Genuine origin row — seeded with code GEN, and the only non-country in the list.
CREATE OR REPLACE FUNCTION qvm_new_apps.genuine_origin_id()
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT oc.origin_country_id FROM qvm_new_apps.origin_countries oc WHERE upper(oc.code) = 'GEN' LIMIT 1;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.is_genuine_class(bigint) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.genuine_origin_id() TO anon, authenticated, service_role;

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
      -- A genuine part's origin is the marque, not a factory: when the line's grade resolves to
      -- Genuine the origin is the Genuine row, whatever the client sent. The grade expression is
      -- repeated rather than referenced because SET sees the row as it was.
      origin_country_id       = CASE
        WHEN qvm_new_apps.is_genuine_class(COALESCE(c.available_brand_class, qvi.available_brand_class,
               (SELECT qi0.brand_class FROM qvm_new_apps.quotation_items qi0 WHERE qi0.quotation_item_id = qvi.quotation_item_id)))
          THEN qvm_new_apps.genuine_origin_id()
        ELSE COALESCE(c.origin_country_id, qvi.origin_country_id) END,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.save_vendor_item_alternative(
  p_cost_id             bigint,
  p_part_number         text,
  p_alternative_id      bigint  DEFAULT NULL,
  p_brand_class         bigint  DEFAULT NULL,
  p_brand_id            bigint  DEFAULT NULL,
  p_origin_country_id   bigint  DEFAULT NULL,
  p_unit_price          numeric DEFAULT NULL,
  p_available_quantity  integer DEFAULT NULL,
  p_delivery_days       integer DEFAULT NULL,
  p_note                text    DEFAULT NULL,
  p_photos              jsonb   DEFAULT NULL,
  p_visible_to_workshop boolean DEFAULT NULL,
  p_token               uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.can_touch_vendor_cost(p_cost_id, p_token) THEN
    RAISE EXCEPTION 'Not allowed to price this line';
  END IF;

  IF COALESCE(btrim(p_part_number), '') = '' THEN
    RAISE EXCEPTION 'An alternative needs a part number';
  END IF;

  -- Genuine means genuine: the origin is the Genuine row, not a country the client picked.
  IF qvm_new_apps.is_genuine_class(p_brand_class) THEN
    p_origin_country_id := qvm_new_apps.genuine_origin_id();
  END IF;

  IF p_alternative_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
      (cost_id, part_number, brand_class, brand_id, origin_country_id, unit_price,
       available_quantity, delivery_days, note, photos, visible_to_workshop, created_by)
    VALUES
      (p_cost_id, btrim(p_part_number), p_brand_class, p_brand_id, p_origin_country_id, p_unit_price,
       p_available_quantity, p_delivery_days, NULLIF(btrim(COALESCE(p_note, '')), ''),
       COALESCE(p_photos, '[]'::jsonb), COALESCE(p_visible_to_workshop, false), auth.uid())
    RETURNING alternative_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.quotation_vendor_item_alternatives a
       SET part_number         = btrim(p_part_number),
           brand_class         = p_brand_class,
           brand_id            = p_brand_id,
           origin_country_id   = p_origin_country_id,
           unit_price          = p_unit_price,
           available_quantity  = p_available_quantity,
           delivery_days       = p_delivery_days,
           note                = NULLIF(btrim(COALESCE(p_note, '')), ''),
           -- Photos are uploaded and removed by their own call; a save that does not mention them
           -- must not wipe them.
           photos              = COALESCE(p_photos, a.photos),
           visible_to_workshop = COALESCE(p_visible_to_workshop, a.visible_to_workshop),
           updated_at          = now()
     WHERE a.alternative_id = p_alternative_id
       AND a.cost_id = p_cost_id
    RETURNING a.alternative_id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'That alternative is not on this line';
    END IF;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'alternative_id', v_id);
END;
$function$;
