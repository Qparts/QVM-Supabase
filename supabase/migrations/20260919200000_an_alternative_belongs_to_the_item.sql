-- An alternative belongs to the item, and the desk offers its own.
--
-- Alternatives were a vendor's: rows on the vendor's line. Now every alternative names the line it
-- is for and where it came from — 'vendor' (with the vendor's price, on the vendor's line) or
-- 'qparts' (added on the Extract PN page, no price, no line). The pricing page lists them all in one
-- place with a show-to-workshop switch each; the workshop sees whichever are shown, labelled by
-- source, and may pick a Qparts one too — at the line's price, since nobody has priced it yet.

ALTER TABLE qvm_new_apps.quotation_vendor_item_alternatives
  ALTER COLUMN cost_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS quotation_item_id bigint,
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'vendor';
UPDATE qvm_new_apps.quotation_vendor_item_alternatives a
   SET quotation_item_id = q.quotation_item_id
  FROM qvm_new_apps.quotation_vendor_items q
 WHERE q.cost_id = a.cost_id AND a.quotation_item_id IS NULL;
DO $$ BEGIN
  ALTER TABLE qvm_new_apps.quotation_vendor_item_alternatives
    ADD CONSTRAINT alternatives_source_check CHECK (source IN ('vendor', 'qparts'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE qvm_new_apps.quotation_vendor_item_alternatives
    ADD CONSTRAINT alternatives_vendor_has_line CHECK (source <> 'vendor' OR cost_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS ix_alternatives_item ON qvm_new_apps.quotation_vendor_item_alternatives (quotation_item_id);

-- A vendor's row keeps naming its line on insert, whatever wrote it.
CREATE OR REPLACE FUNCTION qvm_new_apps.alternatives_fill_item()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NEW.quotation_item_id IS NULL AND NEW.cost_id IS NOT NULL THEN
    SELECT q.quotation_item_id INTO NEW.quotation_item_id FROM qvm_new_apps.quotation_vendor_items q WHERE q.cost_id = NEW.cost_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_alternatives_fill_item ON qvm_new_apps.quotation_vendor_item_alternatives;
CREATE TRIGGER trg_alternatives_fill_item BEFORE INSERT ON qvm_new_apps.quotation_vendor_item_alternatives
FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.alternatives_fill_item();

-- ── The desk's own alternatives ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.save_item_alternative(
  p_quotation_item_id bigint, p_part_number text, p_alternative_id bigint DEFAULT NULL,
  p_brand_class bigint DEFAULT NULL, p_brand_id bigint DEFAULT NULL, p_origin_country_id bigint DEFAULT NULL,
  p_note text DEFAULT NULL, p_photos jsonb DEFAULT NULL, p_visible_to_workshop boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v_id bigint; v_origin bigint := p_origin_country_id;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Only the Qparts team adds alternatives here'; END IF;
  IF COALESCE(btrim(p_part_number), '') = '' THEN RAISE EXCEPTION 'An alternative needs a part number'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id) THEN
    RAISE EXCEPTION 'Unknown line';
  END IF;
  -- Genuine means genuine: the origin is the Genuine row.
  IF qvm_new_apps.is_genuine_class(p_brand_class) THEN v_origin := qvm_new_apps.genuine_origin_id(); END IF;

  IF p_alternative_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
      (cost_id, quotation_item_id, source, part_number, brand_class, brand_id, origin_country_id, note, photos, visible_to_workshop, created_by)
    VALUES (NULL, p_quotation_item_id, 'qparts', btrim(p_part_number), p_brand_class, p_brand_id, v_origin,
            NULLIF(btrim(COALESCE(p_note, '')), ''), COALESCE(p_photos, '[]'::jsonb), COALESCE(p_visible_to_workshop, false), auth.uid())
    RETURNING alternative_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.quotation_vendor_item_alternatives a
       SET part_number = btrim(p_part_number), brand_class = p_brand_class, brand_id = p_brand_id, origin_country_id = v_origin,
           note = NULLIF(btrim(COALESCE(p_note, '')), ''), photos = COALESCE(p_photos, a.photos),
           visible_to_workshop = COALESCE(p_visible_to_workshop, a.visible_to_workshop), updated_at = now()
     WHERE a.alternative_id = p_alternative_id AND a.quotation_item_id = p_quotation_item_id AND a.source = 'qparts'
    RETURNING a.alternative_id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'That alternative is not the desk''s, or not on this line'; END IF;
  END IF;
  RETURN jsonb_build_object('status', 'success', 'alternative_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_item_alternative(p_alternative_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Only the Qparts team removes alternatives here'; END IF;
  -- Only the desk's own: a vendor's alternative is the vendor's to withdraw.
  DELETE FROM qvm_new_apps.quotation_vendor_item_alternatives WHERE alternative_id = p_alternative_id AND source = 'qparts';
  RETURN jsonb_build_object('status', 'success', 'deleted', FOUND);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_item_alternatives(p_quotation_item_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
             'part_number', a.part_number, 'brand_class', a.brand_class, 'brand_class_name', bc.list_data,
             'brand_id', a.brand_id, 'brand_name', br.list_data, 'origin_country_id', a.origin_country_id,
             'origin', COALESCE(oc.name_ar, oc.name_en), 'unit_price', a.unit_price, 'available_quantity', a.available_quantity,
             'delivery_days', a.delivery_days, 'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
     WHERE a.quotation_item_id = p_quotation_item_id), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.save_item_alternative(p_quotation_item_id bigint, p_part_number text, p_alternative_id bigint DEFAULT NULL, p_brand_class bigint DEFAULT NULL, p_brand_id bigint DEFAULT NULL, p_origin_country_id bigint DEFAULT NULL, p_note text DEFAULT NULL, p_photos jsonb DEFAULT NULL, p_visible_to_workshop boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.save_item_alternative(p_quotation_item_id, p_part_number, p_alternative_id, p_brand_class, p_brand_id, p_origin_country_id, p_note, p_photos, p_visible_to_workshop) $$;
CREATE OR REPLACE FUNCTION public.delete_item_alternative(p_alternative_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.delete_item_alternative(p_alternative_id) $$;
CREATE OR REPLACE FUNCTION public.list_item_alternatives(p_quotation_item_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_item_alternatives(p_quotation_item_id) $$;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean)',
    'qvm_new_apps.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean)',
    'public.delete_item_alternative(bigint)', 'qvm_new_apps.delete_item_alternative(bigint)',
    'public.list_item_alternatives(bigint)', 'qvm_new_apps.list_item_alternatives(bigint)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;

-- ── The readers and the pick, source-aware ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_lines(p_quotation_id bigint, p_audience text, p_round_id bigint, p_round_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               -- NULL for a line never put to this audience: there is nothing to answer on it.
               'approval_item_id',  li.approval_item_id,
               'quotation_item_id', qi.quotation_item_id,
               'part_number',       qi.part_number,
               'part_description',  qi.part_description,
               -- The line itself, so the table this feeds can stand in for the order's item list:
               -- where the part is in its life, its photos, how many notes are on it, its class.
               'item_status',       ldst.list_data,
               'item_status_id',    qi.item_status,
               'part_photo',        qi.part_photo,
               'brand_class',       ld_bc.list_data,
               'notes_count',       (SELECT COUNT(*)::int FROM qvm_new_apps.notes n
                                      WHERE n.note_type = 'quotation_items'
                                        AND n.type_id = qi.quotation_item_id
                                        AND n.is_internal = FALSE),
               -- What the vendor said and showed on the offer this line is priced from. The
               -- workshop's business; the customer is not shown the vendor's side.
               'vendor_note',  CASE WHEN p_audience = 'workshop' THEN COALESCE(qvi.note, bq.note) END,
               'vendor_files', CASE WHEN p_audience = 'workshop' THEN COALESCE(qvi.files, bq.files, '[]'::jsonb) ELSE '[]'::jsonb END,
               'quantity',          COALESCE(li.quantity, qi.quantity),
               'delivery_days',     COALESCE(qvi.sla, bq.sla),
               -- The one number this audience is entitled to, under one name either way. From the
               -- round's snapshot when the line was sent; when it was not, from the pricing page's
               -- تسعيرك column and nothing else — سعر الجملة (price_before_vat) for the workshop,
               -- سعر العميل (agency_price) for the customer. A vendor's offer is the pricing team's
               -- material, not a price: until they set one, the line has none.
               'unit_price', CASE WHEN p_audience = 'workshop'
                                  THEN COALESCE(li.wholesale_price, NULLIF(qi.price_before_vat, 0))
                                  ELSE COALESCE(li.customer_price, NULLIF(qi.agency_price, 0)) END,
               'customer_price_reference',
                 CASE WHEN p_audience = 'workshop'
                      THEN COALESCE(li.customer_price, NULLIF(qi.agency_price, 0)) END,
               -- Where this line stands with THIS audience, whichever round it was in.
               'sent',              li.approval_item_id IS NOT NULL,
               'line_round_id',     li.approval_round_id,
               'line_round_status', lr.status,
               -- Only a line in the currently open request can be answered.
               'actionable',        li.approval_round_id = p_round_id AND p_round_status = 'pending',
               'decision',          COALESCE(li.decision, 'pending'),
               'reason',            li.reason,
               -- The choice standing on the line: the approval's when it was sent; before that, the
               -- one on the vendor line — only when the workshop is allowed to see it.
               'chosen_alternative_id',
                 CASE WHEN li.approval_item_id IS NOT NULL AND lr.status = 'pending' THEN li.chosen_alternative_id
                      ELSE (SELECT a.alternative_id FROM qvm_new_apps.quotation_vendor_item_alternatives a
                             WHERE a.alternative_id = COALESCE(qvi.chosen_alternative_id, bq.chosen_alternative_id)
                               AND a.visible_to_workshop) END,
               'options', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'alternative_id', a.alternative_id,
                          'source',         a.source,
                          'part_number',    a.part_number,
                          'brand_class_name', bc.list_data,
                          'brand_name',     br.list_data,
                          'origin', COALESCE(oc.name_ar, oc.name_en),
                          'unit_price',     a.unit_price,
                          'available_quantity', a.available_quantity,
                          'delivery_days',  a.delivery_days,
                          'note',           a.note,
                          'photos',         a.photos) ORDER BY a.alternative_id)
                   FROM qvm_new_apps.quotation_vendor_item_alternatives a
                   LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                   LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                   LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                  WHERE (a.cost_id = COALESCE(li.cost_id, bq.cost_id)
                         OR (a.source = 'qparts' AND a.quotation_item_id = qi.quotation_item_id))
                    AND a.visible_to_workshop), '[]'::jsonb)
             ) ORDER BY qi.quotation_item_id)
        FROM qvm_new_apps.quotation_items qi
        -- The line's most recent appearance in any round for this audience.
        LEFT JOIN LATERAL (
          SELECT ai.*
            FROM qvm_new_apps.quotation_approval_items ai
            JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
           WHERE ai.quotation_item_id = qi.quotation_item_id
             AND ar.quotation_id = p_quotation_id
             AND ar.audience = p_audience
           ORDER BY ai.approval_round_id DESC
           LIMIT 1
        ) li ON true
        LEFT JOIN qvm_new_apps.quotation_approval_rounds lr ON lr.approval_round_id = li.approval_round_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = li.cost_id
        -- For a line never sent: the offer it would be priced from today — the pricing team's pick
        -- when they made one, otherwise the cheapest, the same order the senders use.
        LEFT JOIN LATERAL (
          SELECT v.cost_id, v.cost, v.agency_price, v.sla, v.chosen_alternative_id, v.note, v.files
            FROM qvm_new_apps.quotation_vendor_items v
           WHERE v.quotation_item_id = qi.quotation_item_id
             AND v.cost IS NOT NULL AND v.cost > 0
           ORDER BY (v.cost_id = qi.selected_cost_id) DESC NULLS LAST, v.best_cost DESC, v.cost ASC
           LIMIT 1
        ) bq ON true
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives bch ON bch.alternative_id = bq.chosen_alternative_id
        -- The offer the pricing team picked for the customer price, when they picked one.
        LEFT JOIN qvm_new_apps.quotation_vendor_items cp ON cp.cost_id = qi.customer_price_cost_id
        LEFT JOIN qvm_new_apps.list_data ldst ON ldst.list_data_id = qi.item_status
        LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
       WHERE qi.quotation_id = p_quotation_id
         -- Suggested parts are not part of the order until somebody says so; cancelled ones are gone.
         AND qi.item_status NOT IN (
           SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
            WHERE ld.list_id = 3
              AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))), '[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_pick_alternative(
  p_quotation_item_id bigint, p_alternative_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_qid   bigint;
  v_cost  bigint;
  v_part  text;
  v_class bigint;
  v_wholesale numeric;
  v_customer  numeric;
  v_ratio     numeric;
BEGIN
  SELECT qi.quotation_id INTO v_qid FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_qid IS NULL THEN RAISE EXCEPTION 'Unknown line'; END IF;

  IF NOT (qvm_new_apps.is_qparts_team()
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(v_qid))) THEN
    RAISE EXCEPTION 'Not allowed to choose for this order';
  END IF;

  IF p_alternative_id IS NOT NULL THEN
    -- The option has to be one offered on this line, and one the workshop was shown. A vendor's
    -- alternative names its line; a Qparts alternative names none, and lands on the line the order
    -- is priced from.
    SELECT a.cost_id INTO v_cost
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      LEFT JOIN qvm_new_apps.quotation_vendor_items v ON v.cost_id = a.cost_id
     WHERE a.alternative_id = p_alternative_id
       AND COALESCE(v.quotation_item_id, a.quotation_item_id) = p_quotation_item_id
       AND a.visible_to_workshop;
    IF NOT FOUND THEN RAISE EXCEPTION 'That option is not offered on this line'; END IF;
  END IF;
  IF v_cost IS NULL THEN
    -- Back to the original: on the line the order is priced from — the open request's, else the
    -- pricing team's pick, else the best offer.
    SELECT COALESCE(
      (SELECT ai.cost_id FROM qvm_new_apps.quotation_approval_items ai
         JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
        WHERE ai.quotation_item_id = p_quotation_item_id AND ar.audience = 'workshop' AND ar.status = 'pending'
        ORDER BY ai.approval_round_id DESC LIMIT 1),
      (SELECT qi.selected_cost_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id),
      (SELECT v.cost_id FROM qvm_new_apps.quotation_vendor_items v
        WHERE v.quotation_item_id = p_quotation_item_id AND v.cost IS NOT NULL AND v.cost > 0
        ORDER BY v.best_cost DESC, v.cost ASC LIMIT 1)) INTO v_cost;
    IF v_cost IS NULL THEN RETURN jsonb_build_object('status', 'success', 'chosen_alternative_id', p_alternative_id); END IF;
  END IF;

  -- The vendor line carries the choice: the pricing page reads it, the PO is written from it.
  UPDATE qvm_new_apps.quotation_vendor_items
     SET chosen_alternative_id = p_alternative_id, updated_at = now()
   WHERE cost_id = v_cost;

  -- The line's prices follow the pick. Wholesale is the picked part's after-discount price — the
  -- alternative's, or the vendor line's again for the original. The customer price keeps the line's
  -- own margin: the ratio تسعيرك already held between customer and wholesale, else the vendor's
  -- before/after ratio, else none. Written to the line (what the pricing page's تسعيرك shows) and to
  -- the open request's snapshot, so the approval is of the price actually chosen.
  SELECT CASE WHEN p_alternative_id IS NOT NULL THEN a.unit_price ELSE v.cost END,
         COALESCE(NULLIF(qi.agency_price, 0) / NULLIF(qi.price_before_vat, 0),
                  NULLIF(v.agency_price, 0) / NULLIF(v.cost, 0))
    INTO v_wholesale, v_ratio
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotation_vendor_items v ON v.cost_id = v_cost
    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.alternative_id = p_alternative_id
   WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_wholesale IS NOT NULL AND v_wholesale > 0 THEN
    v_customer := CASE WHEN p_alternative_id IS NULL
                       THEN COALESCE((SELECT NULLIF(v.agency_price, 0) FROM qvm_new_apps.quotation_vendor_items v WHERE v.cost_id = v_cost),
                                     CASE WHEN v_ratio IS NOT NULL THEN round(v_wholesale * v_ratio, 2) END)
                       ELSE CASE WHEN v_ratio IS NOT NULL THEN round(v_wholesale * v_ratio, 2) END END;
    UPDATE qvm_new_apps.quotation_items
       SET price_before_vat = v_wholesale,
           agency_price = COALESCE(v_customer, agency_price),
           total_price_before_vat = v_wholesale * GREATEST(COALESCE(quantity, 1), 1),
           updated_at = now()
     WHERE quotation_item_id = p_quotation_item_id;
  END IF;

  -- The open request, when this line is in one, says the same — the choice and the prices.
  UPDATE qvm_new_apps.quotation_approval_items ai
     SET chosen_alternative_id = p_alternative_id,
         wholesale_price = COALESCE(v_wholesale, ai.wholesale_price),
         customer_price  = COALESCE(v_customer, ai.customer_price)
    FROM qvm_new_apps.quotation_approval_rounds ar
   WHERE ar.approval_round_id = ai.approval_round_id
     AND ai.quotation_item_id = p_quotation_item_id AND ai.cost_id = v_cost
     AND ar.audience = 'workshop' AND ar.status = 'pending';

  -- A line already confirmed but not yet ordered follows too; an ordered one is the PO's now.
  SELECT COALESCE(a.part_number, qi.alternative_part_number, qi.part_number), COALESCE(a.brand_class, qi.brand_class)
    INTO v_part, v_class
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.alternative_id = p_alternative_id
   WHERE qi.quotation_item_id = p_quotation_item_id;
  UPDATE qvm_new_apps.confirmed_items ci
     SET final_part_number = v_part, final_brand_class = v_class, updated_at = now()
    FROM qvm_new_apps.quotation_items qi
   WHERE ci.quotation_item_id = p_quotation_item_id
     AND qi.quotation_item_id = ci.quotation_item_id AND qi.cost_id IS NULL;

  RETURN jsonb_build_object('status', 'success', 'cost_id', v_cost, 'chosen_alternative_id', p_alternative_id,
                            'wholesale_price', v_wholesale, 'customer_price', v_customer);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.decide_approval_items(p_token uuid, p_decisions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round  bigint;
  v_status text;
BEGIN
  SELECT r.approval_round_id, r.status INTO v_round, v_status
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.access_token = p_token AND now() <= r.token_expires_at;

  IF v_round IS NULL THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'already_resolved', 'round_status', v_status);
  END IF;

  UPDATE qvm_new_apps.quotation_approval_items ai
     SET decision = COALESCE(NULLIF(x->>'decision', ''), ai.decision),
         reason   = NULLIF(btrim(COALESCE(x->>'reason', '')), ''),
         chosen_alternative_id =
           CASE WHEN x ? 'chosen_alternative_id'
                THEN NULLIF(x->>'chosen_alternative_id', '')::bigint
                ELSE ai.chosen_alternative_id END,
         decided_at = now()
    FROM jsonb_array_elements(COALESCE(p_decisions, '[]'::jsonb)) AS x
   WHERE ai.approval_round_id = v_round
     AND ai.approval_item_id = (x->>'approval_item_id')::bigint
     -- A chosen option has to be one of the options actually offered on this line, or the approver
     -- could be handed an id belonging to someone else's quote.
     AND (NOT (x ? 'chosen_alternative_id')
          OR NULLIF(x->>'chosen_alternative_id', '') IS NULL
          OR EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_item_alternatives a
                      WHERE a.alternative_id = (x->>'chosen_alternative_id')::bigint
                        AND (a.cost_id = ai.cost_id
                             OR (a.source = 'qparts' AND a.quotation_item_id = ai.quotation_item_id))));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_vendor_pricings(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'status', true,
        'message', 'success',
        'data', jsonb_agg(
            jsonb_build_object(
                'quotation_item_id', qi.quotation_item_id,
                'quotation_id', qi.quotation_id,
                'shipping_price', q.shipping_price,
                'customer_id', qi.customer_id,
                'vin', qi.vin,
                'main_brand', lcd_mb.list_data,
                'model', qi.model,
                'part_description', qi.part_description,
                'part_number', qi.part_number,
                'quantity', qi.quantity,
                -- The class by NAME, as main_brand and part_category already are; the id rides beside it
                -- for anything that needs to write it back.
                'brand_class', lcd_bc.list_data,
                'brand_class_id', qi.brand_class,
                'part_photo', qi.part_photo,
                -- Every alternative on the line, from every source, for the desk's one list.
                'item_alternatives', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
                             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
                             'part_number', a.part_number,
                             'brand_class_name', bc.list_data, 'brand_name', br.list_data,
                             'origin', COALESCE(oc.name_ar, oc.name_en),
                             'unit_price', a.unit_price, 'available_quantity', a.available_quantity, 'delivery_days', a.delivery_days,
                             'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
                             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
                      FROM qvm_new_apps.quotation_vendor_item_alternatives a
                      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                     WHERE a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb),
                -- How many of the line are already on purchase orders (cancelled purchase lines excluded).
                'ordered_qty', (SELECT COALESCE(SUM(pi.approved_qty), 0)::int
                                  FROM qvm_new_apps.purchase_items pi
                                  JOIN qvm_new_apps.quotation_vendor_items pq ON pq.cost_id = pi.cost_id
                                  LEFT JOIN qvm_new_apps.list_data pst ON pst.list_data_id = pi.vendor_item_status
                                 WHERE pq.quotation_item_id = qi.quotation_item_id
                                   AND COALESCE(pst.list_data, '') NOT ILIKE 'cancel%'),
                -- Every note on the line, internal ones included: this is the buying desk's page.
                'item_notes_count', (SELECT COUNT(*)::int FROM qvm_new_apps.notes n
                                      WHERE n.note_type = 'quotation_items' AND n.type_id = qi.quotation_item_id),
                'item_status', qi.item_status,
                'alternative_part_number', qi.alternative_part_number,
                'price_before_vat', qi.price_before_vat,
                'discount_percent', qi.discount_percent,
                'total_price_before_vat', qi.total_price_before_vat,
                'cost_id', qi.cost_id,
                'purchase_cost', qvi_pur.cost,
                'purchase_vendor', v_pur.vendor_name,
                'part_category', lcd_pc.list_data,
                'agency_price', qi.agency_price,
                'created_at', qi.created_at,
                'updated_at', qi.updated_at,
                'vendor_pricing', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'cost_id', qvi.cost_id,
                            'quotation_item_id', qvi.quotation_item_id,
                            'cost', qvi.cost,
                            'vendor_name', v.vendor_name,
                            'vendor_branch_id', qv.vendor_branch_id,
                            'vendor_branch_city', vb.city,
                            'vendor_branch_name', vb.branch_name,
                            'vendor_shipping_cost', (
                                SELECT pi.vendor_shipping_cost
                                FROM qvm_new_apps.purchase_items pi
                                WHERE pi.cost_id = qvi.cost_id
                                LIMIT 1
                            ),
                            'item_shipping', qvi.item_shipping,
                            'vendor_item_status', lcd_vis.list_data,
                            'vendor_item_status_id', qvi.vendor_item_status,
                            'discount_percent', qvi.discount_percent,
                            'agency_price', qvi.agency_price,
                            'from_database', qvi.from_database,
                            'sla', qvi.sla,
                            'best_cost', qvi.best_cost,
                            'available_quantity', qvi.available_quantity,
                            'confirmed_quantity', qvi.confirmed_quantity,
                            'quotation_vendor_id', qvi.quotation_vendor_id,
                            'available_brand_class', lcd_abc.list_data,
                            'alternative_part_number', qvi.alternative_part_number,
                            -- The alternatives this vendor offered on this line, and which one the
                            -- buyer chose to take instead of the part that was asked for. The
                            -- effective figures are what the purchase order and the approvals use.
                            'chosen_alternative_id', qvi.chosen_alternative_id,
                            'note', qvi.note,
                            'vendor_part_number', qvi.vendor_part_number,
                            'files', COALESCE(qvi.files, '[]'::jsonb),
                            'improvement_requested_at', qvi.improvement_requested_at,
                            'improvement_note', qvi.improvement_note,
                            'previous_cost', qvi.previous_cost,
                            'effective_cost', COALESCE(ch.unit_price, qvi.cost),
                            'effective_part_number', COALESCE(ch.part_number, qvi.vendor_part_number),
                            'alternatives', COALESCE((
                                SELECT jsonb_agg(jsonb_build_object(
                                         'alternative_id',     a.alternative_id,
                                         'source',             a.source,
                                         'part_number',        a.part_number,
                                         'brand_class_name',   bc.list_data,
                                         'brand_name',         br.list_data,
                                         'origin',             COALESCE(oc.name_ar, oc.name_en),
                                         'unit_price',         a.unit_price,
                                         'available_quantity', a.available_quantity,
                                         'delivery_days',      a.delivery_days,
                                         'note',               a.note,
                                         'photos',             a.photos,
                                         'visible_to_workshop', a.visible_to_workshop) ORDER BY a.alternative_id)
                                  FROM qvm_new_apps.quotation_vendor_item_alternatives a
                                  LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                                  LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                                  LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                                 WHERE a.cost_id = qvi.cost_id), '[]'::jsonb),
                            'created_at', qvi.created_at,
                            'updated_at', qvi.updated_at,
                            'is_best_price', (
                                qvi.cost = (
                                    SELECT MIN(cost)
                                    FROM qvm_new_apps.quotation_vendor_items
                                    WHERE quotation_item_id = qi.quotation_item_id
                                )
                            ),
                            'selling_price',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (1 + (pm.percentage)), 2)
                                    ELSE 0
                                END,
                            'profit_value',
                                CASE
                                    WHEN pm.percentage IS NOT NULL AND qvi.cost IS NOT NULL
                                    THEN ROUND(qvi.cost * (pm.percentage), 2)
                                    ELSE 0
                                END,
                            'profit_percentage',
                                COALESCE(pm.percentage, 0)
                        )
                    )
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    LEFT JOIN qvm_new_apps.list_data lcd_abc
                        ON qvi.available_brand_class = lcd_abc.list_data_id
                    LEFT JOIN qvm_new_apps.list_data lcd_vis
                        ON qvi.vendor_item_status = lcd_vis.list_data_id
                    LEFT JOIN qvm_new_apps.vendors v
                        ON qvi.vendor_id = v.vendor_id
                    LEFT JOIN qvm_new_apps.quotation_vendors qv
                        ON qv.quotation_vendor_id = qvi.quotation_vendor_id
                    LEFT JOIN qvm_new_apps.vendor_branches vb
                        ON vb.vendor_branch_id = qv.vendor_branch_id
                    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch
                        ON ch.alternative_id = qvi.chosen_alternative_id
                    LEFT JOIN qvm_new_apps.profit_categories pc
                        ON pc.brand_class = qi.brand_class
                       AND pc.part_category = qi.part_category
                    LEFT JOIN qvm_new_apps.cost_categories cc
                        ON qvi.cost >= (cc.cost_range->>0)::numeric
                        AND qvi.cost <  (cc.cost_range->>1)::numeric
                    LEFT JOIN qvm_new_apps.profit_margins pm
                        ON pm.profit_categories_id = pc.category_id
                        AND pm.cost_range_id = cc.cost_range_id
                  WHERE qvi.quotation_item_id = qi.quotation_item_id
                    AND (
                        cc.cost_range IS NULL
                        OR qvi.cost IS NULL
                        OR (
                            qvi.cost >= (cc.cost_range->>0)::numeric
                            AND qvi.cost <  (cc.cost_range->>1)::numeric
                        )
                    )
                )
            )
            ORDER BY qi.quotation_item_id DESC
        )
    )
    INTO result
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotations q ON qi.quotation_id = q.quotation_id
    LEFT JOIN qvm_new_apps.list_data lcd_pc
           ON qi.part_category = lcd_pc.list_data_id
    LEFT JOIN qvm_new_apps.list_data lcd_mb
           ON qi.main_brand = lcd_mb.list_data_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi_pur
           ON qvi_pur.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.vendors v_pur
           ON v_pur.vendor_id = qvi_pur.vendor_id
    LEFT JOIN qvm_new_apps.list_data lcd_bc ON lcd_bc.list_data_id = qi.brand_class
    WHERE q.order_number = p_order_number;

    RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_extract_pn_order(p_quotation_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_order jsonb; v_parts jsonb;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope int[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
begin
  -- Opening an order by id has to be checked too: the queue may hide it, but the id is guessable
  -- and the page fetches straight from it.
  if v_scope is not null and not exists (
       select 1 from qvm_new_apps.quotation_items qi
        where qi.quotation_id = p_quotation_id and qi.customer_id = any (v_scope)) then
    return jsonb_build_object('status', false, 'message', 'Not found', 'data', null);
  end if;

  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;

  select to_jsonb(o) into v_order from (
    select q.quotation_id, q.order_number, q.plate_number, q.created_at as rfq_date,
           coalesce(bmain.list_data,'') as brand, coalesce(f.model,'') as model,
           coalesce(f.year::text,'') as year, coalesce(f.vin,'') as vin,
           coalesce(cb.branch_name,'') as branch_name, coalesce(ldc.list_data,'') as client_name,
           coalesce(am.user_name,'') as manager,
           greatest(0, (extract(epoch from (now() - q.created_at)) / 60)::int) as waiting_minutes,
           q.extract_locked_by,
           (q.extract_locked_by is not null and coalesce(q.extract_lock_touched_at, q.extract_locked_at) > now() - interval '30 minutes') as lock_live,
           (select ud.user_name from qvm_new_apps.user_data ud where ud.user_id = q.extract_locked_by) as locked_by_name,
           (q.extract_locked_by = v_uid) as locked_by_me,
           (select count(*) from qvm_new_apps.quotation_items u
             where u.quotation_id = q.quotation_id and u.extraction_status = 'unclear')::int as unclear_count
    from qvm_new_apps.quotations q
    left join lateral (
      select qi2.model, qi2.year, qi2.vin, qi2.main_brand, qi2.customer_id
      from qvm_new_apps.quotation_items qi2 where qi2.quotation_id = q.quotation_id
      order by qi2.quotation_item_id limit 1
    ) f on true
    left join qvm_new_apps.list_data bmain on bmain.list_data_id = f.main_brand
    left join qvm_new_apps.client_branches cb on cb.customer_id = f.customer_id
    left join qvm_new_apps.list_data ldc on ldc.list_data_id = cb.list_data_id
    left join qvm_new_apps.user_data am on am.user_id = q.account_manager
    where q.quotation_id = p_quotation_id
  ) o;

  if v_order is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_id'); end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.added_at_extraction desc nulls last,
                                                p.quotation_item_id desc), '[]'::jsonb)
    into v_parts from (
    select qi.quotation_item_id, coalesce(qi.part_description,'') as part_description,
           coalesce(qi.part_number,'') as part_number,
           coalesce(qi.draft_part_number,'') as draft_part_number,
           qi.pn_state, qi.quantity,
           qi.extraction_status, qi.extraction_unclear_reason,
           coalesce((select ud.user_name from qvm_new_apps.user_data ud
                      where ud.user_id = qi.extraction_flagged_by), '') as unclear_by,
           coalesce(qi.added_at_extraction, false) as added_at_extraction,
           (coalesce(qi.added_at_extraction, false) and qi.created_by = v_uid) as can_remove,
           -- Added here and not yet approved by the workshop: shown, but not part of the order yet.
           (qi.item_status = (select ld.list_data_id from qvm_new_apps.list_data ld
                               where ld.list_id = 3 and ld.list_data = 'Pending Workshop Approval' limit 1)) as awaiting_workshop,
           coalesce((select bc.list_data from qvm_new_apps.list_data bc where bc.list_data_id = qi.brand_class), '') as brand_class_name,
           coalesce((select jsonb_agg(a.alt_part_number order by a.alt_pn_id)
                     from qvm_new_apps.quotation_item_alt_pns a
                     where a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alt_pns,
           -- Alternative items on the line: the extractor's own, and the vendors'.
           coalesce((select jsonb_agg(jsonb_build_object(
                       'alternative_id', al.alternative_id, 'source', al.source, 'part_number', al.part_number,
                       'brand_class_name', bc.list_data, 'brand_name', br.list_data,
                       'origin', coalesce(oc.name_ar, oc.name_en), 'note', al.note,
                       'visible_to_workshop', al.visible_to_workshop,
                       'vendor_name', (select v3.vendor_name from qvm_new_apps.quotation_vendor_items q3
                                         join qvm_new_apps.vendors v3 on v3.vendor_id = q3.vendor_id where q3.cost_id = al.cost_id),
                       'can_remove', al.source = 'qparts') order by al.source desc, al.alternative_id)
                     from qvm_new_apps.quotation_vendor_item_alternatives al
                     left join qvm_new_apps.list_data bc on bc.list_data_id = al.brand_class
                     left join qvm_new_apps.list_data br on br.list_data_id = al.brand_id
                     left join qvm_new_apps.origin_countries oc on oc.origin_country_id = al.origin_country_id
                     where al.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alternatives
    from qvm_new_apps.quotation_items qi
    where qi.quotation_id = p_quotation_id
      and (qi.item_status = any (array[235, 236])
           or qi.item_status = (select ld.list_data_id from qvm_new_apps.list_data ld
                                 where ld.list_id = 3 and ld.list_data = 'Pending Workshop Approval' limit 1))
  ) p;

  return jsonb_build_object('status', true, 'message', 'OK',
    'data', jsonb_build_object('order', v_order, 'parts', v_parts));
end $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 24 $$;
