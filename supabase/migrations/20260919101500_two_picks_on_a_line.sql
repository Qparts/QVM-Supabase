-- Two picks on a line, each persisted, each read by what depends on it.
--
-- The buyer picks two vendors on a line and they may differ: the one to BUY from, whose price after
-- discount is the sell price, the purchase order and what the workshop confirms — and the one whose
-- price BEFORE discount the customer is asked to approve. Until now only the first existed, and only
-- in the browser: the approval rounds and the reopen-on-reprice path re-derived "the vendor" from a
-- best-price heuristic that could disagree with what was clicked.
--
-- Both picks now live on the line. Not in quotation_items.cost_id — that column means "the purchase
-- order was created on this vendor line", and the pricing page paints those cells PO Created from
-- it; a pick is not a PO.

ALTER TABLE qvm_new_apps.quotation_items
  ADD COLUMN IF NOT EXISTS selected_cost_id       bigint,
  ADD COLUMN IF NOT EXISTS customer_price_cost_id bigint;

-- The buyer's pick. kind 'buy' is the vendor bought from; 'customer' is the vendor whose
-- before-discount price the customer sees. NULL clears. A cost_id from another line is refused.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_item_vendor_pick(p_quotation_item_id bigint, p_kind text, p_cost_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can pick a vendor for a line';
  END IF;
  IF p_kind NOT IN ('buy', 'customer') THEN RAISE EXCEPTION 'Unknown pick: %', p_kind; END IF;
  IF p_cost_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.quotation_vendor_items v
        WHERE v.cost_id = p_cost_id AND v.quotation_item_id = p_quotation_item_id) THEN
    RAISE EXCEPTION 'That vendor line is not on this item';
  END IF;
  IF p_kind = 'buy' THEN
    UPDATE qvm_new_apps.quotation_items SET selected_cost_id = p_cost_id, updated_at = now()
     WHERE quotation_item_id = p_quotation_item_id;
  ELSE
    UPDATE qvm_new_apps.quotation_items SET customer_price_cost_id = p_cost_id, updated_at = now()
     WHERE quotation_item_id = p_quotation_item_id;
  END IF;
  RETURN jsonb_build_object('status', 'success');
END;
$function$;
CREATE OR REPLACE FUNCTION public.set_item_vendor_pick(p_quotation_item_id bigint, p_kind text, p_cost_id bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.set_item_vendor_pick(p_quotation_item_id, p_kind, p_cost_id); $$;
REVOKE ALL ON FUNCTION public.set_item_vendor_pick(bigint, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_item_vendor_pick(bigint, text, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.set_item_vendor_pick(bigint, text, bigint) TO authenticated, service_role;

-- ── The pricing grid carries both picks ───────────────────────────────────────────────────────
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
                'brand_class', qi.brand_class,
                'part_photo', qi.part_photo,
                'item_status', qi.item_status,
                'alternative_part_number', qi.alternative_part_number,
                'price_before_vat', qi.price_before_vat,
                'discount_percent', qi.discount_percent,
                'total_price_before_vat', qi.total_price_before_vat,
                'cost_id', qi.cost_id,
                -- The buyer's two picks: the vendor bought from, and the vendor whose before-discount
                -- price the customer is asked to approve. Persisted so approvals and the PO agree with
                -- what was clicked, rather than re-deriving a vendor from a best-price heuristic.
                'selected_cost_id', qi.selected_cost_id,
                'customer_price_cost_id', qi.customer_price_cost_id,
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
                            'quotation_vendor_id', qvi.quotation_vendor_id,
                            'available_brand_class', lcd_abc.list_data,
                            'alternative_part_number', qvi.alternative_part_number,
                            -- The alternatives this vendor offered on this line, and which one the
                            -- buyer chose to take instead of the part that was asked for. The
                            -- effective figures are what the purchase order and the approvals use.
                            'chosen_alternative_id', qvi.chosen_alternative_id,
                            'improvement_requested_at', qvi.improvement_requested_at,
                            'improvement_note', qvi.improvement_note,
                            'previous_cost', qvi.previous_cost,
                            'effective_cost', COALESCE(ch.unit_price, qvi.cost),
                            'effective_part_number', COALESCE(ch.part_number, qvi.vendor_part_number),
                            'alternatives', COALESCE((
                                SELECT jsonb_agg(jsonb_build_object(
                                         'alternative_id',     a.alternative_id,
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
    WHERE q.order_number = p_order_number;

    RETURN result;
END;
$function$;

-- ── Every sender reads the picks: bought-from vendor first, customer price from its own pick ──
CREATE OR REPLACE FUNCTION qvm_new_apps.send_quotation_for_approval(
  p_quotation_id bigint, p_audiences text[], p_item_ids bigint[] DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_audience text;
  v_round    bigint;
  v_customer bigint;
  v_out      jsonb := '[]'::jsonb;
  v_count    integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can send an order for approval';
  END IF;

  SELECT q.end_customer_id INTO v_customer
    FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id;

  FOREACH v_audience IN ARRAY COALESCE(p_audiences, ARRAY[]::text[]) LOOP
    IF v_audience NOT IN ('workshop', 'client') THEN
      RAISE EXCEPTION 'Unknown approval audience: %', v_audience;
    END IF;

    -- Re-sending while a round is open reuses it rather than raising a second one; the unique index
    -- would refuse the insert anyway, and silently failing would be worse than reusing.
    SELECT r.approval_round_id INTO v_round
      FROM qvm_new_apps.quotation_approval_rounds r
     WHERE r.quotation_id = p_quotation_id AND r.audience = v_audience AND r.status = 'pending';

    IF v_round IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_approval_rounds
        (quotation_id, audience, end_customer_id, sent_by)
      VALUES (p_quotation_id, v_audience,
              CASE WHEN v_audience = 'client' THEN v_customer END, auth.uid())
      RETURNING approval_round_id INTO v_round;
    END IF;

    -- The lines, priced from the vendor offer currently marked best — or the only one there is.
    -- Both prices are snapshotted on every round regardless of audience: the round records what was
    -- true, and the read function decides what the reader is shown.
    -- The line as the buyer chose it: the vendor marked best (or cheapest), and, when the buyer took
    -- one of that vendor's alternatives instead of the part asked for, the alternative's price and
    -- id — so the approver is shown, and approves, exactly what will be bought.
    INSERT INTO qvm_new_apps.quotation_approval_items
      (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity, chosen_alternative_id)
    SELECT v_round, qi.quotation_item_id, best.cost_id, COALESCE(best.alt_price, best.cost),
           COALESCE(best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN LATERAL (
        SELECT qvi.cost_id, qvi.cost, qvi.agency_price, qvi.chosen_alternative_id, ch.unit_price AS alt_price,
               -- The customer is asked about the before-discount price of the vendor picked FOR the
               -- customer (the indigo radio); failing that, of the vendor bought from.
               COALESCE(cp.agency_price, qvi.agency_price) AS customer_before_price
          FROM qvm_new_apps.quotation_vendor_items qvi
          LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
          LEFT JOIN qvm_new_apps.quotation_vendor_items cp ON cp.cost_id = qi.customer_price_cost_id
         WHERE qvi.quotation_item_id = qi.quotation_item_id
           AND qvi.cost IS NOT NULL AND qvi.cost > 0
         -- The vendor the buyer picked to buy from comes first; the best offer only when nobody picked.
         ORDER BY (qvi.cost_id = qi.selected_cost_id) DESC NULLS LAST, qvi.best_cost DESC, qvi.cost ASC
         LIMIT 1
      ) best ON true
     WHERE qi.quotation_id = p_quotation_id
       AND (p_item_ids IS NULL OR qi.quotation_item_id = ANY(p_item_ids))
       -- A line this audience has already confirmed is settled. It is never put to them again, however
       -- many times the rest of the order goes back — only the lines they have not confirmed travel.
       AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, v_audience)))
       -- A part still waiting on somebody's decision is not part of the order yet, so it is not
       -- part of what is being approved either.
       AND qi.item_status NOT IN (
         SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
          WHERE ld.list_id = 3
            AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
    ON CONFLICT (approval_round_id, quotation_item_id) DO UPDATE
      SET cost_id         = EXCLUDED.cost_id,
          wholesale_price = EXCLUDED.wholesale_price,
          customer_price  = EXCLUDED.customer_price,
          quantity        = EXCLUDED.quantity,
          chosen_alternative_id = EXCLUDED.chosen_alternative_id;

    UPDATE qvm_new_apps.quotation_approval_rounds r
       SET total_amount = (
             SELECT COALESCE(SUM(COALESCE(CASE WHEN v_audience = 'workshop'
                                               THEN ai.wholesale_price ELSE ai.customer_price END, 0)
                                 * COALESCE(ai.quantity, 1)), 0)
               FROM qvm_new_apps.quotation_approval_items ai
              WHERE ai.approval_round_id = v_round AND ai.decision <> 'cancelled')
     WHERE r.approval_round_id = v_round;

    SELECT count(*) INTO v_count
      FROM qvm_new_apps.quotation_approval_items WHERE approval_round_id = v_round;

    -- Every line this audience could be asked about is already confirmed. An empty round would sit
    -- in their queue as a request with nothing in it; say so instead, and leave no round behind.
    IF v_count = 0 THEN
      DELETE FROM qvm_new_apps.quotation_approval_rounds
       WHERE approval_round_id = v_round
         AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_items WHERE approval_round_id = v_round);
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'audience', v_audience, 'items', 0, 'status', 'nothing_to_send'));
      CONTINUE;
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'approval_round_id', v_round,
      'audience', v_audience,
      'items', v_count,
      'access_token', (SELECT r.access_token FROM qvm_new_apps.quotation_approval_rounds r
                        WHERE r.approval_round_id = v_round)));
  END LOOP;

  RETURN jsonb_build_object('status', 'success', 'rounds', v_out);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.send_quotation_for_approval_core(
  p_quotation_id bigint, p_audience text, p_round bigint)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  INSERT INTO qvm_new_apps.quotation_approval_items
    (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity, chosen_alternative_id)
  SELECT p_round, qi.quotation_item_id, best.cost_id, COALESCE(best.alt_price, best.cost),
         COALESCE(best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN LATERAL (
      SELECT qvi.cost_id, qvi.cost, qvi.agency_price, qvi.chosen_alternative_id, ch.unit_price AS alt_price,
             -- The customer is asked about the before-discount price of the vendor picked FOR the
             -- customer (the indigo radio); failing that, of the vendor bought from.
             COALESCE(cp.agency_price, qvi.agency_price) AS customer_before_price
        FROM qvm_new_apps.quotation_vendor_items qvi
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items cp ON cp.cost_id = qi.customer_price_cost_id
       WHERE qvi.quotation_item_id = qi.quotation_item_id
         AND qvi.cost IS NOT NULL AND qvi.cost > 0
       -- The vendor the buyer picked to buy from comes first; the best offer only when nobody picked.
       ORDER BY (qvi.cost_id = qi.selected_cost_id) DESC NULLS LAST, qvi.best_cost DESC, qvi.cost ASC
       LIMIT 1
    ) best ON true
   WHERE qi.quotation_id = p_quotation_id
     AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, p_audience)))
     AND qi.item_status NOT IN (
       SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
        WHERE ld.list_id = 3
          AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
  ON CONFLICT (approval_round_id, quotation_item_id) DO NOTHING;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.reopen_workshop_approval_for_changed_price(p_quotation_item_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_qid    bigint;
  v_last   record;
  v_round  bigint;
  v_part   text;
  v_order  text;
BEGIN
  SELECT qi.quotation_id, COALESCE(qi.part_number, qi.part_description)
    INTO v_qid, v_part
    FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_qid IS NULL THEN RETURN jsonb_build_object('reopened', false); END IF;

  -- The line's most recent appearance in a workshop round. Only "sent back for a better price"
  -- qualifies; anything else — waiting, confirmed, cancelled, never sent — is left alone.
  SELECT ar.approval_round_id, ar.status INTO v_last
    FROM qvm_new_apps.quotation_approval_items ai
    JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
   WHERE ai.quotation_item_id = p_quotation_item_id
     AND ar.quotation_id = v_qid AND ar.audience = 'workshop'
   ORDER BY ai.approval_round_id DESC
   LIMIT 1;
  IF v_last IS NULL OR v_last.status <> 'revision_requested' THEN
    RETURN jsonb_build_object('reopened', false);
  END IF;

  -- The open workshop request, or a new one. One pending round per audience — the index sees to it.
  SELECT r.approval_round_id INTO v_round
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = v_qid AND r.audience = 'workshop' AND r.status = 'pending';
  IF v_round IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_approval_rounds (quotation_id, audience, sent_by)
    VALUES (v_qid, 'workshop', auth.uid())
    RETURNING approval_round_id INTO v_round;
  END IF;

  -- The line at its price as of now: the best offer, and the chosen alternative if one is chosen.
  INSERT INTO qvm_new_apps.quotation_approval_items
    (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity, chosen_alternative_id)
  SELECT v_round, qi.quotation_item_id, best.cost_id, COALESCE(best.alt_price, best.cost),
         COALESCE(best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN LATERAL (
      SELECT qvi.cost_id, qvi.cost, qvi.agency_price, qvi.chosen_alternative_id, ch.unit_price AS alt_price,
             -- The customer is asked about the before-discount price of the vendor picked FOR the
             -- customer (the indigo radio); failing that, of the vendor bought from.
             COALESCE(cp.agency_price, qvi.agency_price) AS customer_before_price
        FROM qvm_new_apps.quotation_vendor_items qvi
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items cp ON cp.cost_id = qi.customer_price_cost_id
       WHERE qvi.quotation_item_id = qi.quotation_item_id
         AND qvi.cost IS NOT NULL AND qvi.cost > 0
       -- The vendor the buyer picked to buy from comes first; the best offer only when nobody picked.
       ORDER BY (qvi.cost_id = qi.selected_cost_id) DESC NULLS LAST, qvi.best_cost DESC, qvi.cost ASC
       LIMIT 1
    ) best ON true
   WHERE qi.quotation_item_id = p_quotation_item_id
  ON CONFLICT (approval_round_id, quotation_item_id) DO UPDATE
    SET cost_id = EXCLUDED.cost_id, wholesale_price = EXCLUDED.wholesale_price,
        customer_price = EXCLUDED.customer_price, quantity = EXCLUDED.quantity,
        chosen_alternative_id = EXCLUDED.chosen_alternative_id,
        -- A fresh price is a fresh question, whatever the workshop said about the old one.
        decision = 'pending', reason = NULL, decided_at = NULL;

  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET total_amount = (SELECT COALESCE(SUM(COALESCE(ai.wholesale_price, 0) * COALESCE(ai.quantity, 1)), 0)
                           FROM qvm_new_apps.quotation_approval_items ai
                          WHERE ai.approval_round_id = v_round AND ai.decision <> 'cancelled')
   WHERE r.approval_round_id = v_round;

  SELECT order_number INTO v_order FROM qvm_new_apps.quotations WHERE quotation_id = v_qid;

  WITH sent AS (
    INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
    SELECT 'تغيّر سعر قطعة طلبتَ تحسينها',
           'تغيّر سعر ' || COALESCE(v_part, '') || ' في الطلب ' || COALESCE(v_order, '') || ' — بانتظار اعتمادك',
           jsonb_build_object('quotation_id', v_qid, 'quotation_item_id', p_quotation_item_id,
                              'approval_round_id', v_round, 'kind', 'price_changed'),
           'user', w, auth.uid()
      FROM qvm_new_apps.workshop_users_for_quotation(v_qid) AS w
    RETURNING id, target_user_id
  )
  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  SELECT sent.id, sent.target_user_id FROM sent WHERE sent.target_user_id IS NOT NULL;

  RETURN jsonb_build_object('reopened', true, 'approval_round_id', v_round);
END;
$function$;
