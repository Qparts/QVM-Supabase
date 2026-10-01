-- The alternatives a part number was offered before land on its next line by themselves.
--
-- The previous migration told the desk what was known for a part number from earlier orders and
-- let it add one by hand. The desk wants them on the new line without asking: in the procurement
-- dashboard, the RFQs dashboard, the pricing page, the approval panel — every reader of the line's
-- alternatives. So a line that gets a part number (on creation, or later from Extract PN) inherits
-- the originals offered for that part number on earlier lines, as the desk's own alternatives:
-- the part, class, brand, origin, note and photos, and whether the workshop saw it; not the
-- earlier order's price, which belonged to that order and is kept as a reference. Each copy
-- remembers the offer it came from, and open lines already on the books get theirs now.

ALTER TABLE qvm_new_apps.quotation_vendor_item_alternatives
  ADD COLUMN IF NOT EXISTS inherited_from bigint
    REFERENCES qvm_new_apps.quotation_vendor_item_alternatives(alternative_id) ON DELETE SET NULL;
COMMENT ON COLUMN qvm_new_apps.quotation_vendor_item_alternatives.inherited_from IS
  'The alternative on an earlier line of the same part number this one was copied from; null for an original offer.';
CREATE INDEX IF NOT EXISTS ix_alternatives_inherited_from
  ON qvm_new_apps.quotation_vendor_item_alternatives (inherited_from);
-- Lines are found by their normalised part number, on every new line and on every dashboard row.
CREATE INDEX IF NOT EXISTS ix_quotation_items_normalized_part_number
  ON qvm_new_apps.quotation_items (qvm_new_apps.normalize_part_number(part_number));

CREATE OR REPLACE FUNCTION qvm_new_apps.known_part_alternatives(p_quotation_item_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  WITH me AS (
    SELECT qi.quotation_item_id, qvm_new_apps.normalize_part_number(qi.part_number) AS pn
      FROM qvm_new_apps.quotation_items qi
     WHERE qi.quotation_item_id = p_quotation_item_id
  ),
  mine AS (
    SELECT qvm_new_apps.normalize_part_number(a.part_number) AS pn,
           COALESCE(a.brand_class, 0) AS brand_class, COALESCE(a.brand_id, 0) AS brand_id
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
     WHERE a.quotation_item_id = p_quotation_item_id
  ),
  offers AS (
    SELECT DISTINCT ON (qvm_new_apps.normalize_part_number(a.part_number), COALESCE(a.brand_class, 0), COALESCE(a.brand_id, 0), COALESCE(v.vendor_id, 0))
           a.*, q.order_number, pi.quotation_item_id AS from_quotation_item_id, v.vendor_name
      FROM me
      JOIN qvm_new_apps.quotation_items pi
        ON pi.quotation_item_id <> me.quotation_item_id
       AND qvm_new_apps.normalize_part_number(pi.part_number) = me.pn
      JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.quotation_item_id = pi.quotation_item_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = pi.quotation_id
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = a.cost_id
      LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
     WHERE me.pn IS NOT NULL
       -- Originals only: a copy another line inherited is the same offer, and points back here.
       AND a.inherited_from IS NULL
       AND COALESCE(btrim(a.part_number), '') <> ''
       AND NOT EXISTS (SELECT 1 FROM mine m
                        WHERE m.pn IS NOT DISTINCT FROM qvm_new_apps.normalize_part_number(a.part_number)
                          AND m.brand_class = COALESCE(a.brand_class, 0) AND m.brand_id = COALESCE(a.brand_id, 0))
     ORDER BY qvm_new_apps.normalize_part_number(a.part_number), COALESCE(a.brand_class, 0), COALESCE(a.brand_id, 0), COALESCE(v.vendor_id, 0),
              a.created_at DESC, a.alternative_id DESC
  )
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'alternative_id', o.alternative_id, 'source', o.source, 'cost_id', o.cost_id,
             'vendor_name', o.vendor_name, 'order_number', o.order_number, 'from_quotation_item_id', o.from_quotation_item_id,
             'part_number', o.part_number, 'brand_class', o.brand_class, 'brand_class_name', bc.list_data,
             'brand_id', o.brand_id, 'brand_name', br.list_data, 'origin_country_id', o.origin_country_id,
             'origin', COALESCE(oc.name_ar, oc.name_en), 'unit_price', o.unit_price, 'available_quantity', o.available_quantity,
             'delivery_days', o.delivery_days, 'note', o.note, 'photos', o.photos, 'visible_to_workshop', o.visible_to_workshop,
             'created_at', o.created_at) ORDER BY o.created_at DESC, o.alternative_id DESC)
      FROM (SELECT * FROM offers LIMIT 50) o
      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = o.brand_class
      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = o.brand_id
      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = o.origin_country_id), '[]'::jsonb);
$function$;


-- Puts the known originals on the line, one per distinct offer (part, class, brand), newest first.
-- Returns how many it added; nothing when the line already has them, so it can run again.
CREATE OR REPLACE FUNCTION qvm_new_apps.inherit_known_alternatives(p_quotation_item_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
    (cost_id, quotation_item_id, source, part_number, brand_class, brand_id, origin_country_id,
     unit_price, available_quantity, delivery_days, note, photos, visible_to_workshop, created_by, inherited_from)
  SELECT DISTINCT ON (qvm_new_apps.normalize_part_number(x.part_number), COALESCE(x.brand_class, 0), COALESCE(x.brand_id, 0))
         NULL, p_quotation_item_id, 'qparts', x.part_number, x.brand_class, x.brand_id, x.origin_country_id,
         NULL, NULL, NULL, x.note, COALESCE(x.photos, '[]'::jsonb), COALESCE(x.visible_to_workshop, false),
         COALESCE(auth.uid(), (SELECT s.created_by FROM qvm_new_apps.quotation_vendor_item_alternatives s WHERE s.alternative_id = x.alternative_id)),
         x.alternative_id
    FROM jsonb_to_recordset(qvm_new_apps.known_part_alternatives(p_quotation_item_id))
         AS x(alternative_id bigint, part_number text, brand_class bigint, brand_id bigint, origin_country_id bigint,
              note text, photos jsonb, visible_to_workshop boolean, created_at timestamptz)
   ORDER BY qvm_new_apps.normalize_part_number(x.part_number), COALESCE(x.brand_class, 0), COALESCE(x.brand_id, 0),
            x.created_at DESC, x.alternative_id DESC;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.inherit_known_alternatives(bigint) FROM PUBLIC, anon, authenticated;

-- A line that gets a part number — on creation, or later from Extract PN — inherits what is known
-- for it. Never in the way of the line itself: a failure here is a warning, not a refused write.
CREATE OR REPLACE FUNCTION qvm_new_apps.alternatives_follow_the_part_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF qvm_new_apps.normalize_part_number(NEW.part_number) IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND qvm_new_apps.normalize_part_number(OLD.part_number) IS NOT DISTINCT FROM qvm_new_apps.normalize_part_number(NEW.part_number) THEN
    RETURN NEW;
  END IF;
  BEGIN
    PERFORM qvm_new_apps.inherit_known_alternatives(NEW.quotation_item_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'alternatives_follow_the_part_number(%): %', NEW.quotation_item_id, SQLERRM;
  END;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS trg_alternatives_follow_the_part_number ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_alternatives_follow_the_part_number
  AFTER INSERT OR UPDATE OF part_number ON qvm_new_apps.quotation_items
  FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.alternatives_follow_the_part_number();

-- The modal's list says where an inherited alternative was first offered, and at what price then.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_item_alternatives(p_quotation_item_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
             'part_number', a.part_number, 'brand_class', a.brand_class, 'brand_class_name', bc.list_data,
             'brand_id', a.brand_id, 'brand_name', br.list_data, 'origin_country_id', a.origin_country_id,
             'origin_country_name_en', oc.name_en, 'origin_country_name_ar', oc.name_ar,
             'origin', COALESCE(oc.name_ar, oc.name_en), 'unit_price', a.unit_price, 'available_quantity', a.available_quantity,
             'delivery_days', a.delivery_days, 'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
             'inherited_from', a.inherited_from,
             'inherited_from_order', sq.order_number,
             'reference_price', s.unit_price,
             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
      LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives s ON s.alternative_id = a.inherited_from
      LEFT JOIN qvm_new_apps.quotation_items si ON si.quotation_item_id = s.quotation_item_id
      LEFT JOIN qvm_new_apps.quotations sq ON sq.quotation_id = si.quotation_id
     WHERE a.quotation_item_id = p_quotation_item_id), '[]'::jsonb);
END $function$;

-- The dashboard's per-line list carries the same two facts.
CREATE OR REPLACE FUNCTION public.get_internal_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_account_managers uuid[] DEFAULT NULL::uuid[], p_clients integer[] DEFAULT NULL::integer[], p_branches integer[] DEFAULT NULL::integer[], p_brands integer[] DEFAULT NULL::integer[], p_statuses integer[] DEFAULT NULL::integer[], p_insurance_company_ids bigint[] DEFAULT NULL::bigint[], p_mode text DEFAULT 'regular'::text, p_view text DEFAULT 'rfqs'::text, p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0, p_quotation_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_branch_scope integer[];
  v_result jsonb;
  v_rfq_statuses  int[] := ARRAY[17, 216, 217, 218, 235, 236, 237];
  -- Settled(31) belongs with the order statuses: it is what a Delivered line becomes once the
  -- vendor invoice lands, and leaving it out made finished orders vanish from the Orders view.
  v_order_statuses int[] := ARRAY[19, 21, 22, 23, 31];
BEGIN
  SELECT user_type INTO v_user_type
  FROM qvm_new_apps.user_data WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Access denied: Internal users only',
      'data', '[]'::jsonb
    );
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(p_user_id);

  WITH filtered_quotations AS (
    SELECT DISTINCT
      q.quotation_id,
      q.order_number,
      q.plate_number,
      q.created_at AS rfq_date,
      q.service_advisor,
      q.delivery_type,
      q.order_type,
      q.shipping_price,
      q.shipping_type,
      q.account_manager,
      q.insurance_company_id,
      q.end_customer_id,
      q.customer_address_id,
      q.end_customer_address_id,
      co.confirmed_order_id,
      co.created_at AS confirmation_date,
      (
        SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC LIMIT 1
      ) AS customer_id,
      (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
      ) AS order_search_matched
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = q.quotation_id
    WHERE
      EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi_any WHERE qi_any.quotation_id = q.quotation_id)
      AND (p_quotation_ids IS NULL OR q.quotation_id = ANY(p_quotation_ids))
      AND (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_account_managers IS NULL OR q.account_manager = ANY(p_account_managers))
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi2
          LEFT JOIN qvm_new_apps.confirmed_items ci2 ON ci2.quotation_item_id = qi2.quotation_item_id
          WHERE qi2.quotation_id = q.quotation_id
            AND (
              qi2.part_number ILIKE '%' || p_search || '%'
              OR qi2.part_description ILIKE '%' || p_search || '%'
              OR qi2.vin ILIKE '%' || p_search || '%'
              OR ci2.final_part_number ILIKE '%' || p_search || '%'
            )
        )
      )
      AND (
        p_view = 'all'
        OR (p_view = 'rfqs' AND (
          co.confirmed_order_id IS NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_rfq_statuses)
          )
        ))
        OR (p_view = 'orders' AND (
          co.confirmed_order_id IS NOT NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_order_statuses)
          )
        ))
      )
  ),
  filtered_with_branch AS (
    SELECT
      fq.*,
      cb.customer_id AS branch_id,
      cb.branch_name,
      cb.list_data_id AS client_id,
      cb.is_bulk_client,
      ld_client.list_data AS client_name,
      ic.name AS insurance_company_name,
      vec.name AS end_customer_name
    FROM filtered_quotations fq
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fq.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = fq.insurance_company_id
    LEFT JOIN qvm_new_apps.v_end_customers vec ON vec.end_customer_id = fq.end_customer_id
    WHERE
      (p_branches IS NULL OR cb.customer_id = ANY(p_branches))
      AND (p_clients IS NULL OR cb.list_data_id = ANY(p_clients))
      AND (p_insurance_company_ids IS NULL OR fq.insurance_company_id = ANY(p_insurance_company_ids))
      AND (v_branch_scope IS NULL OR cb.customer_id = ANY(v_branch_scope))
      AND (
        (p_mode = 'bulk' AND cb.is_bulk_client = true)
        OR (p_mode = 'regular' AND (cb.is_bulk_client = false OR cb.is_bulk_client IS NULL))
        OR p_mode IS NULL
      )
  ),
  paged_filtered AS (
    SELECT * FROM filtered_with_branch
    ORDER BY rfq_date DESC
    LIMIT GREATEST(p_limit, 1)
    OFFSET GREATEST(p_offset, 0)
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Internal dashboard data fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered_with_branch),
    'data', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'quotation_id', fwb.quotation_id,
            'confirmed_order_id', fwb.confirmed_order_id,
            'order_number', fwb.order_number,
            'plate_number', fwb.plate_number,
            'rfq_date', fwb.rfq_date,
            'confirmation_date', fwb.confirmation_date,
            'branch_id', fwb.branch_id,
            'branch_name', fwb.branch_name,
            'client_id', fwb.client_id,
            'client_name', fwb.client_name,
            'is_bulk_client', fwb.is_bulk_client,
            'insurance_company_id', fwb.insurance_company_id,
            'insurance_company_name', fwb.insurance_company_name,
            'end_customer_id', fwb.end_customer_id,
            'end_customer_name', fwb.end_customer_name,
            'service_advisor', sa.user_name,
            'service_advisor_id', fwb.service_advisor,
            'delivery_type', ld_delivery.list_data,
            'delivery_type_id', fwb.delivery_type,
            'order_type', ld_order.list_data,
            'order_type_id', fwb.order_type,
            'shipping_price', fwb.shipping_price,
            'shipping_type', fwb.shipping_type,
            'account_manager', am.user_name,
            'account_manager_id', fwb.account_manager,
            'account_manager_history', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'account_manager_id', qam.assigned_to,
                  'account_manager_name', am_hist.user_name,
                  'assigned_at', qam.created_at
                )
                ORDER BY qam.created_at DESC
              )
              FROM qvm_new_apps.quotation_account_managers qam
              LEFT JOIN qvm_new_apps.user_data am_hist ON am_hist.user_id = qam.assigned_to
              WHERE qam.quotation_id = fwb.quotation_id
            ),
            'items', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'quotation_item_id', qi.quotation_item_id,
                  'vin', qi.vin,
                  'main_brand', ld_brand.list_data,
                  'main_brand_id', qi.main_brand,
                  'model', qi.model,
                  'year', qi.year,
                  'part_number', qi.part_number,
                  'part_description', qi.part_description,
                  'quantity', qi.quantity,
                  'brand_class', ld_bc.list_data,
                  'brand_class_id', qi.brand_class,
                  'alternative_part_number', qi.alternative_part_number,
                  -- Every alternative item on the line, from every source, for the Alt Part Number column.
                  'alternatives', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                     'alternative_id', a.alternative_id, 'source', a.source, 'part_number', a.part_number,
                                     'brand_class_name', abc.list_data, 'brand_name', abr.list_data,
                                     'origin', COALESCE(aoc.name_ar, aoc.name_en),
                                     'unit_price', a.unit_price, 'available_quantity', a.available_quantity, 'delivery_days', a.delivery_days,
                                     'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
                                     -- Where an inherited alternative was first offered, and at what price then.
                                     'inherited_from_order', (SELECT q4.order_number FROM qvm_new_apps.quotation_vendor_item_alternatives s4
                                                                JOIN qvm_new_apps.quotation_items i4 ON i4.quotation_item_id = s4.quotation_item_id
                                                                JOIN qvm_new_apps.quotations q4 ON q4.quotation_id = i4.quotation_id
                                                               WHERE s4.alternative_id = a.inherited_from),
                                     'reference_price', (SELECT s5.unit_price FROM qvm_new_apps.quotation_vendor_item_alternatives s5 WHERE s5.alternative_id = a.inherited_from),
                                     'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                                                       JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id))
                                     ORDER BY (a.source = 'qparts') DESC, a.alternative_id), '[]'::jsonb)
                                     FROM qvm_new_apps.quotation_vendor_item_alternatives a
                                     LEFT JOIN qvm_new_apps.list_data abc ON abc.list_data_id = a.brand_class
                                     LEFT JOIN qvm_new_apps.list_data abr ON abr.list_data_id = a.brand_id
                                     LEFT JOIN qvm_new_apps.origin_countries aoc ON aoc.origin_country_id = a.origin_country_id
                                    WHERE a.quotation_item_id = qi.quotation_item_id),
                  -- Alternatives this part number was offered on earlier orders and this line has not got yet.
                  'known_alternatives', jsonb_array_length(qvm_new_apps.known_part_alternatives(qi.quotation_item_id)),
                  'alternative_brand_class', ld_abc.list_data,
                  'alternative_brand_class_id', qi.alternative_brand_class,
                  'part_photo', qi.part_photo,
                  'estimated_price', qi.estimated_price,
                  'price_before_vat', qi.price_before_vat,
                  'discount_percent', qi.discount_percent,
                  'agency_price', qi.agency_price,
                  'total_price_before_vat', qi.total_price_before_vat,
                  'item_status', ld_status.list_data,
                  'item_status_id', qi.item_status,
                  'part_category', ld_category.list_data,
                  'part_category_id', qi.part_category,
                  'final_part_number', ci.final_part_number,
                  'approved_qty', ci.approved_qty,
                  'final_brand_class', ld_fbc.list_data,
                  'final_brand_class_id', ci.final_brand_class,
                  'return_type', ld_return.list_data,
                  'return_type_id', ci.return_type,
                  'client_return_reason', ci.client_return_reason,
                  'cancellation_reason', ld_cancel.list_data,
                  'cancellation_reason_id', ci.cancellation_reason,
                  'purchase_cost', qvi.cost,
                  'purchase_supplier', qvi.vendor_id,
                  'item_notes', (
                    SELECT jsonb_agg(
                      jsonb_build_object(
                        'note_id', n.note_id,
                        'note_text', n.note_description,
                        'created_by', n_creator.user_name,
                        'created_at', n.created_at
                      )
                      ORDER BY n.created_at DESC
                    )
                    FROM qvm_new_apps.notes n
                    LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
                    WHERE n.note_type = 'quotation_items'
                      AND n.type_id = qi.quotation_item_id
                      AND n.is_internal = false
                      AND n.deleted_at IS NULL
                  )
                )
                ORDER BY qi.quotation_item_id ASC
              )
              FROM qvm_new_apps.quotation_items qi
              LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
              LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
              LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
              LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
              LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = qi.item_status
              LEFT JOIN qvm_new_apps.list_data ld_category ON ld_category.list_data_id = qi.part_category
              LEFT JOIN qvm_new_apps.list_data ld_fbc ON ld_fbc.list_data_id = ci.final_brand_class
              LEFT JOIN qvm_new_apps.list_data ld_return ON ld_return.list_data_id = ci.return_type
              LEFT JOIN qvm_new_apps.list_data ld_cancel ON ld_cancel.list_data_id = ci.cancellation_reason
              LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
              WHERE qi.quotation_id = fwb.quotation_id
                AND (p_brands IS NULL OR qi.main_brand = ANY(p_brands))
                AND (p_statuses IS NULL OR qi.item_status = ANY(p_statuses))
                AND (
                  p_view = 'all'
                  OR (p_view = 'rfqs'    AND qi.item_status = ANY(v_rfq_statuses))
                  OR (p_view = 'orders'  AND qi.item_status = ANY(v_order_statuses))
                )
                AND (
                  fwb.order_search_matched
                  OR p_search IS NULL
                  OR qi.part_number ILIKE '%' || p_search || '%'
                  OR qi.part_description ILIKE '%' || p_search || '%'
                  OR qi.vin ILIKE '%' || p_search || '%'
                  OR ci.final_part_number ILIKE '%' || p_search || '%'
                )
            ),
            'quotation_notes', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'note_id', n.note_id,
                  'note_text', n.note_description,
                  'created_by', n_creator.user_name,
                  'created_at', n.created_at
                )
                ORDER BY n.created_at DESC
              )
              FROM qvm_new_apps.notes n
              LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
              WHERE n.note_type = 'quotations'
                AND n.type_id = fwb.quotation_id
                AND n.is_internal = false
                AND n.deleted_at IS NULL
            ),
            'payment_account', (
              SELECT ld_payment.list_data
              FROM qvm_new_apps.purchase_orders po
              LEFT JOIN qvm_new_apps.list_data ld_payment ON ld_payment.list_data_id = po.payment_account
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            ),
            -- Where the parts are going. The order's own address when it named one; otherwise the
            -- branch's default, marked as such — every order raised before the delivery-address
            -- field existed named nothing, and showing a blank column for all of them would say
            -- less than saying where that branch normally receives.
            'delivery_address', (
              SELECT jsonb_build_object(
                       'address_id', a.address_id,
                       'label', a.label,
                       'address_line', a.address_line,
                       'city', COALESCE(vc.name, a.city),
                       'district', vd.name,
                       'postal_code', a.postal_code,
                       'contact_name', a.contact_name,
                       'contact_phone', a.contact_phone,
                       'is_branch_default', fwb.customer_address_id IS NULL)
                FROM qvm_new_apps.customer_addresses a
                LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
                LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
               WHERE a.address_id = COALESCE(
                       fwb.customer_address_id,
                       (SELECT d.address_id FROM qvm_new_apps.customer_addresses d
                         WHERE d.client_branch_id = fwb.branch_id
                           AND d.is_active AND d.is_default
                         LIMIT 1))
               LIMIT 1),
            -- The end customer's own address: the one the order named, otherwise the customer's
            -- default delivery address standing in for it, marked as such.
            'customer_address', (
              SELECT jsonb_build_object(
                       'address_id', a.address_id,
                       'label', a.label,
                       'address_line', COALESCE(NULLIF(btrim(a.address_line), ''),
                                        NULLIF(concat_ws(' ', a.building_number, a.street, a.short_address), '')),
                       'city', COALESCE(vc.name, a.city),
                       'district', vd.name,
                       'branch_name', ecb.branch_name,
                       'is_customer_default', fwb.end_customer_address_id IS NULL)
                FROM qvm_new_apps.end_customer_addresses a
                JOIN qvm_new_apps.end_customer_branches ecb ON ecb.end_customer_branch_id = a.end_customer_branch_id
                LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
                LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
               WHERE fwb.end_customer_id IS NOT NULL
                 AND a.address_id = COALESCE(
                       fwb.end_customer_address_id,
                       (SELECT d.address_id FROM qvm_new_apps.end_customer_addresses d
                          JOIN qvm_new_apps.end_customer_branches db ON db.end_customer_branch_id = d.end_customer_branch_id
                         WHERE db.end_customer_id = fwb.end_customer_id
                           AND d.is_active AND d.is_delivery
                         ORDER BY d.is_default DESC, d.address_id
                         LIMIT 1))
               LIMIT 1),
            'payment_account_id', (
              SELECT po.payment_account
              FROM qvm_new_apps.purchase_orders po
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            )
          )
          ORDER BY fwb.rfq_date DESC
        )
        FROM paged_filtered fwb
        LEFT JOIN qvm_new_apps.user_data sa ON sa.user_id = fwb.service_advisor
        LEFT JOIN qvm_new_apps.user_data am ON am.user_id = fwb.account_manager
        LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = fwb.delivery_type
        LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = fwb.order_type
      ),
      '[]'::jsonb
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$function$;

-- Open lines already on the books get what was known for their part number.
DO $$
DECLARE r record; v_total integer := 0; v_lines integer := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT qi.quotation_item_id
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      JOIN qvm_new_apps.quotation_items src ON src.quotation_item_id = a.quotation_item_id
      JOIN qvm_new_apps.quotation_items qi
        ON qvm_new_apps.normalize_part_number(qi.part_number) = qvm_new_apps.normalize_part_number(src.part_number)
       AND qi.quotation_item_id <> src.quotation_item_id
     WHERE a.inherited_from IS NULL
       AND qi.item_status IN (15, 16, 17, 235, 236, 237)
  LOOP
    v_lines := v_lines + 1;
    v_total := v_total + qvm_new_apps.inherit_known_alternatives(r.quotation_item_id);
  END LOOP;
  RAISE NOTICE 'alternatives inherited: % on % open lines', v_total, v_lines;
END $$;
