-- The pricing screens carry the alternatives, the brand and the origin.
--
-- Three functions the two vendor pricing pages already live on, taught about what the new grid
-- shows. Each is reproduced whole rather than patched in place: these are plpgsql bodies, and
-- PL/pgSQL resolves column names at run time, so a half-updated body deploys cleanly and fails on
-- every call. Reproducing them keeps the deploy honest about what it is replacing.

-- Alternatives belong to a cost line and are read as a set with it; this is the one shape both the
-- detail loader and the standalone list RPC want, so it lives in one place.
CREATE OR REPLACE FUNCTION qvm_new_apps.alternatives_of_cost(p_cost_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alternative_id',      a.alternative_id,
           'cost_id',             a.cost_id,
           'part_number',         a.part_number,
           'brand_class',         a.brand_class,
           'brand_class_name',    bc.list_data,
           'brand_id',            a.brand_id,
           'brand_name',          br.list_data,
           'origin_country_id',   a.origin_country_id,
           'origin_country_name_en', oc.name_en,
           'origin_country_name_ar', oc.name_ar,
           'unit_price',          a.unit_price,
           'available_quantity',  a.available_quantity,
           'delivery_days',       a.delivery_days,
           'note',                a.note,
           'photos',              a.photos,
           'visible_to_workshop', a.visible_to_workshop,
           'created_at',          a.created_at) ORDER BY a.alternative_id), '[]'::jsonb)
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
   WHERE a.cost_id = p_cost_id;
$function$;

-- No grant. This one takes a raw cost_id and asks nobody's permission -- it is only ever called
-- from inside get_vendor_quotation_details, which has already decided the caller may see the line,
-- and a SECURITY DEFINER body runs as the owner, so it needs no EXECUTE of its own. Handing it to
-- anon would be an alternatives-by-cost_id enumerator. list_vendor_item_alternatives is the gated
-- way in for anyone calling from outside.
REVOKE ALL ON FUNCTION qvm_new_apps.alternatives_of_cost(bigint) FROM PUBLIC;

-- ── The detail loader now returns the alternatives, the offered brand and the origin ──────────
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
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_quotation_details(integer, integer, bigint[], bigint) TO anon, authenticated, service_role;

-- ── The magic link's reference lists gain brands and origin countries ─────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_extras_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_quotation_id integer;
  v_quotation_vendor_id bigint;
  v_vendor_id bigint;
  v_expires_at timestamptz;
begin
  select qv.quotation_id, qv.quotation_vendor_id, qv.vendor_id, qv.token_expires_at
    into v_quotation_id, v_quotation_vendor_id, v_vendor_id, v_expires_at
    from qvm_new_apps.quotation_vendors qv
   where qv.access_token = p_token;

  -- Same two answers the detail loader gives, so the page can treat them alike.
  if v_quotation_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if now() > v_expires_at then
    return jsonb_build_object('status', 'expired');
  end if;

  return jsonb_build_object(
    'status', 'ok',

    -- Only this vendor's own rows on this quotation. Another vendor's part
    -- numbers on the same quotation are not theirs to see.
    'vendor_part_numbers', coalesce((
      select jsonb_object_agg(x.cost_id::text, x.vendor_part_number)
        from qvm_new_apps.quotation_vendor_items x
       where x.quotation_vendor_id = v_quotation_vendor_id
         and x.vendor_part_number is not null
         and btrim(x.vendor_part_number) <> ''), '{}'::jsonb),

    -- Keyed by item id, for the lines of this quotation only.
    'item_years', coalesce((
      select jsonb_object_agg(i.quotation_item_id::text, i.year)
        from qvm_new_apps.quotation_items i
       where i.quotation_id = v_quotation_id
         and i.year is not null and btrim(i.year::text) <> ''), '{}'::jsonb),

    -- A reference list, not anyone's data — the same rows get_brand_classes
    -- returns, minus the login it insists on.
    'brand_classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'brand_class_id', ld.list_data_id,
               'brand_class_name', ld.list_data) order by ld.list_data_id)
        from qvm_new_apps.list_data ld
        join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'brand_class'), '[]'::jsonb),

    -- The other two halves of the grade/brand/origin column. Reference lists like brand_classes
    -- above -- the magic link has no session, so it cannot call the logged-in list RPCs.
    'brands', qvm_new_apps.list_part_brands(),
    'origin_countries', qvm_new_apps.list_origin_countries(),

    -- This vendor's own files on this quotation, whoever uploaded them. Scoped by vendor_id, so
    -- another vendor's quote on the same order is never returned, and neither are the team's
    -- internal order-level files (which carry no vendor_id).
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attachment_id', a.attachment_id,
               'quotation_id',  a.quotation_id,
               'vendor_id',     a.vendor_id,
               'quotation_vendor_id', a.quotation_vendor_id,
               'file_url',      a.file_url,
               'file_path',     a.file_path,
               'file_name',     a.file_name,
               'file_type',     a.file_type,
               'mime_type',     a.mime_type,
               'file_size',     a.file_size,
               'ai_extracted',  a.ai_extracted,
               'created_at',    a.created_at,
               'created_by',    a.created_by) order by a.created_at desc)
        from qvm_new_apps.quotation_attachments a
       where a.quotation_id = v_quotation_id
         and a.vendor_id is not null
         and a.vendor_id = v_vendor_id), '[]'::jsonb)
  );
end
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_vendor_quotation_extras_by_token(uuid) TO anon, authenticated, service_role;

-- ── The bulk save persists the offered brand and origin ───────────────────────────────────────
--
-- Both follow the COALESCE-to-existing pattern the rest of the columns use: a save that does not
-- mention a field leaves it alone, which is what lets the grid send only what the vendor touched.
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
      available_brand_id      = COALESCE(c.available_brand_id, qvi.available_brand_id),
      origin_country_id       = COALESCE(c.origin_country_id, qvi.origin_country_id),
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
