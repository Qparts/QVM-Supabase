-- A line confirmed once stays confirmed, and a vendor's new item carries both prices.
--
-- Sending an order for approval a second time asked the workshop — or the customer — about every
-- line again, the ones they had already said yes to included. A confirmed line is settled: however
-- many times the rest of the order goes back, only the lines that audience has not confirmed travel,
-- and when there are none left the send says so instead of leaving an empty request in their queue.
--
-- And a vendor suggesting a new item could give one price. Their own grid works in two — the price
-- after discount and the price before it — so the suggestion does too.

-- Every line this audience has confirmed, in any round of this order. Cancelled and pending lines
-- are not in it: a cancelled line was refused, not agreed, and may be put again after repricing.
CREATE OR REPLACE FUNCTION qvm_new_apps.approved_item_ids(p_quotation_id bigint, p_audience text)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(array_agg(DISTINCT ai.quotation_item_id), ARRAY[]::bigint[])
    FROM qvm_new_apps.quotation_approval_items ai
    JOIN qvm_new_apps.quotation_approval_rounds r ON r.approval_round_id = ai.approval_round_id
   WHERE r.quotation_id = p_quotation_id
     AND r.audience = p_audience
     AND ai.decision = 'approved'
     AND r.status = 'approved';
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.approved_item_ids(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.approved_item_ids(bigint, text) TO authenticated, service_role;

-- A trailing default is a new overload; the old shape goes first.
DROP FUNCTION IF EXISTS public.add_quotation_item_by_vendor(int, text, text, int, int, numeric, text);

CREATE OR REPLACE FUNCTION public.add_quotation_item_by_vendor(
  p_quotation_id int, p_part_number text DEFAULT NULL, p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1, p_brand_class int DEFAULT NULL, p_cost numeric DEFAULT NULL, p_note text DEFAULT NULL,
  p_agency_price numeric DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid(); v_vendor bigint; v_utype text; v_qv_id bigint;
  v_status_added int; v_order_number text; v_next_index int; v_line_item_code text; v_item_id bigint;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','error','message','Not authenticated'); END IF;
  SELECT ud.user_vendor, ud.user_type::text INTO v_vendor, v_utype FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_user;
  IF v_vendor IS NULL OR v_utype <> '205' THEN RETURN jsonb_build_object('status','error','message','Only vendor users can add items'); END IF;
  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;
  IF v_order_number IS NULL THEN RETURN jsonb_build_object('status','error','message','Invalid quotation_id'); END IF;

  SELECT quotation_vendor_id INTO v_qv_id FROM qvm_new_apps.quotation_vendors
  WHERE quotation_id = p_quotation_id AND vendor_id = v_vendor LIMIT 1;
  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
    VALUES (v_vendor, p_quotation_id, now()) RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  SELECT list_data_id INTO v_status_added FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(line_item_code,''),'^.*-([0-9]+)$','\1'),'')::int),0) + 1
  INTO v_next_index FROM qvm_new_apps.quotation_items WHERE quotation_id = p_quotation_id;
  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id, part_description, part_number, quantity, brand_class,
    item_status, created_by, created_at, updated_at, line_item_code
  ) VALUES (
    p_quotation_id, NULLIF(p_part_description,''), NULLIF(p_part_number,''),
    COALESCE(p_quantity,1), p_brand_class, v_status_added, v_user, now(), now(), v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  -- The two prices the vendor's own grid works in: cost is the price after discount (سعر الجملة),
  -- agency_price the price before it (سعر العميل), and the discount is derived, never typed.
  INSERT INTO qvm_new_apps.quotation_vendor_items (
    quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost, agency_price, discount_percent,
    from_database, vendor_item_status, created_at, updated_at
  ) VALUES (
    v_item_id, v_vendor, v_qv_id, false, p_cost, p_agency_price,
    CASE WHEN COALESCE(p_agency_price, 0) > 0 AND p_cost IS NOT NULL
         THEN round(((p_agency_price - p_cost) / p_agency_price) * 100, 2) END,
    false, NULL, now(), now());

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(p_note_type := 'quotation_items', p_type_id := v_item_id,
        p_note_description := p_note, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','quotation_item_id', v_item_id, 'line_item_code', v_line_item_code);
END; $$;

REVOKE ALL ON FUNCTION public.add_quotation_item_by_vendor(int,text,text,int,int,numeric,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_quotation_item_by_vendor(int,text,text,int,int,numeric,text,numeric) TO authenticated;

-- ── Only the unconfirmed lines travel ─────────────────────────────────────────────────────────
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
   WHERE qi.quotation_id = p_quotation_id
     AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, p_audience)))
     AND qi.item_status NOT IN (
       SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
        WHERE ld.list_id = 3
          AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
  ON CONFLICT (approval_round_id, quotation_item_id) DO NOTHING;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_sends_to_client(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_customer bigint;
  v_round    bigint;
  v_count    integer;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_team()
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id))) THEN
    RAISE EXCEPTION 'Only the workshop of this order can send it to the customer';
  END IF;

  SELECT q.end_customer_id INTO v_customer FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id;
  IF v_customer IS NULL THEN
    RETURN jsonb_build_object('status', 'no_customer',
                              'message', 'This order has no customer to send to');
  END IF;

  SELECT r.approval_round_id INTO v_round
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = p_quotation_id AND r.audience = 'client' AND r.status = 'pending';

  IF v_round IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_approval_rounds (quotation_id, audience, end_customer_id, sent_by)
    VALUES (p_quotation_id, 'client', v_customer, auth.uid())
    RETURNING approval_round_id INTO v_round;
  END IF;

  -- The customer is asked about what the workshop accepted: the lines the workshop's own round
  -- approved, at the selling price. Lines the workshop cancelled are not put to the customer.
  INSERT INTO qvm_new_apps.quotation_approval_items
    (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity)
  SELECT v_round, wi.quotation_item_id, wi.cost_id, wi.wholesale_price, wi.customer_price, wi.quantity
    FROM qvm_new_apps.quotation_approval_items wi
    JOIN qvm_new_apps.quotation_approval_rounds wr ON wr.approval_round_id = wi.approval_round_id
   WHERE wr.quotation_id = p_quotation_id AND wr.audience = 'workshop'
     AND wr.approval_round_id = (SELECT max(approval_round_id) FROM qvm_new_apps.quotation_approval_rounds
                                  WHERE quotation_id = p_quotation_id AND audience = 'workshop')
     AND wi.decision <> 'cancelled'
     -- Lines the customer already confirmed in an earlier round stay confirmed.
     AND NOT (wi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'client')))
  ON CONFLICT (approval_round_id, quotation_item_id) DO UPDATE
    SET cost_id = EXCLUDED.cost_id, wholesale_price = EXCLUDED.wholesale_price,
        customer_price = EXCLUDED.customer_price, quantity = EXCLUDED.quantity;

  -- No workshop round at all: fall back to the order's own lines, priced from the best offer.
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    PERFORM qvm_new_apps.send_quotation_for_approval_core(p_quotation_id, 'client', v_round);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_items WHERE approval_round_id = v_round) THEN
    DELETE FROM qvm_new_apps.quotation_approval_rounds WHERE approval_round_id = v_round;
    RETURN jsonb_build_object('status', 'nothing_to_send',
                              'message', 'The customer has already confirmed every line');
  END IF;

  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET total_amount = (SELECT COALESCE(SUM(COALESCE(ai.customer_price, 0) * COALESCE(ai.quantity, 1)), 0)
                           FROM qvm_new_apps.quotation_approval_items ai
                          WHERE ai.approval_round_id = v_round AND ai.decision <> 'cancelled')
   WHERE r.approval_round_id = v_round;

  RETURN jsonb_build_object('status', 'success', 'approval_round_id', v_round,
                            'access_token', (SELECT access_token FROM qvm_new_apps.quotation_approval_rounds
                                              WHERE approval_round_id = v_round));
END;
$function$;
