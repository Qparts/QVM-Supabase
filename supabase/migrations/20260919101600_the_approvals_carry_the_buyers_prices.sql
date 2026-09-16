-- The approvals carry the buyer's two prices, not the vendor's.
--
-- The pricing page's تسعيرك column now holds exactly two figures the buyer owns: سعر الجملة, the
-- price after discount (quotation_items.price_before_vat — the number that marks a line priced), and
-- سعر العميل, the price before discount (quotation_items.agency_price). Picking a vendor fills both
-- from that vendor's offer; the buyer may then change either by hand. What the workshop is asked to
-- confirm is the first, what the customer is asked to approve is the second — as they stand in that
-- column, falling back to the picked vendor's own figures only where the column is blank.

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
    SELECT v_round, qi.quotation_item_id, best.cost_id, COALESCE(NULLIF(qi.price_before_vat, 0), best.alt_price, best.cost),
           COALESCE(NULLIF(qi.agency_price, 0), best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
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
  SELECT p_round, qi.quotation_item_id, best.cost_id, COALESCE(NULLIF(qi.price_before_vat, 0), best.alt_price, best.cost),
         COALESCE(NULLIF(qi.agency_price, 0), best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
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
  SELECT v_round, qi.quotation_item_id, best.cost_id, COALESCE(NULLIF(qi.price_before_vat, 0), best.alt_price, best.cost),
         COALESCE(NULLIF(qi.agency_price, 0), best.customer_before_price, best.agency_price), qi.quantity, best.chosen_alternative_id
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
