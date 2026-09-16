-- A better price, once given, goes back to the workshop on its own.
--
-- The workshop asked for a better price; the buyer put that to the vendors; a vendor answered with
-- a new number. Until now that new number sat on the pricing page waiting for someone to notice it
-- and press "request workshop approval" again. The line the workshop sent back now returns to them
-- the moment its price changes — as a new request, with a notification saying the price changed
-- and needs checking — whether the change came from the vendor's grid or from the pricing page.
--
-- Only lines whose latest workshop round asked for a better price. A price change on a line the
-- workshop already confirmed must not silently reopen it: that is a different conversation, and a
-- deliberate one.

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
         COALESCE(NULLIF(qi.price_before_vat, 0), best.agency_price), qi.quantity, best.chosen_alternative_id
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN LATERAL (
      SELECT qvi.cost_id, qvi.cost, qvi.agency_price, qvi.chosen_alternative_id, ch.unit_price AS alt_price
        FROM qvm_new_apps.quotation_vendor_items qvi
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
       WHERE qvi.quotation_item_id = qi.quotation_item_id
         AND qvi.cost IS NOT NULL AND qvi.cost > 0
       ORDER BY qvi.best_cost DESC, qvi.cost ASC
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
REVOKE ALL ON FUNCTION qvm_new_apps.reopen_workshop_approval_for_changed_price(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.reopen_workshop_approval_for_changed_price(bigint) TO authenticated, service_role;

-- ── The bulk save fires it ────────────────────────────────────────────────────────────────────
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
