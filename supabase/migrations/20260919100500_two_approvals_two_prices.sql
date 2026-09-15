-- Being priced is not being approved.
--
-- A line reaching 158 means a vendor answered. It has never meant anyone agreed to buy. Until now
-- the pricing team's own save was the end of the story, and the workshop and the customer found out
-- what they were paying afterwards. Two approvals sit in between now, and they are approvals of two
-- different numbers:
--
--   الورشة  approves سعر الجملة — the vendor's price AFTER discount, which is also what the
--           purchase order is written on, from the vendor who gave it.
--   العميل  approves سعر العميل — the vendor's price BEFORE discount.
--
-- No markup and no policy: both figures already exist on the vendor's line as cost and agency_price.
-- Nothing is computed here, which is the point — an approval has to be of a number the approver can
-- be shown again later, not of a formula that moves.
--
-- The audience is what decides which number is visible, and that is enforced in the read function
-- rather than in the page: the customer sees سعر العميل and nothing else. The workshop sees سعر
-- الجملة, with سعر العميل beside it for reference, because the workshop is the one who will have to
-- put that figure to the customer.

-- The order's customer is an end_customers row — the one chosen when the RFQ was raised. Not the
-- old customers table, which is the *company*: an end customer can belong to a workshop or to a
-- vendor, and can be an individual, an insurer, a company or a government entity.
ALTER TABLE qvm_new_apps.quotations
  ADD COLUMN IF NOT EXISTS end_customer_id bigint
    REFERENCES qvm_new_apps.end_customers(end_customer_id);

CREATE TABLE IF NOT EXISTS qvm_new_apps.quotation_approval_rounds (
  approval_round_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  quotation_id      bigint  NOT NULL,
  audience          text    NOT NULL CHECK (audience IN ('workshop', 'client')),
  status            text    NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'approved', 'rejected', 'revision_requested')),
  -- Snapshot of the total the approver was shown. The vendor lines behind it can be re-quoted;
  -- what was agreed cannot change retroactively because someone repriced afterwards.
  total_amount      numeric(14,2),
  end_customer_id   bigint REFERENCES qvm_new_apps.end_customers(end_customer_id),

  -- The client has no login. Same device as the vendor RFQ: a token in a mailed link, and an expiry,
  -- so a forwarded link stops working rather than living forever in someone's inbox.
  access_token      uuid    NOT NULL DEFAULT gen_random_uuid(),
  token_expires_at  timestamptz NOT NULL DEFAULT (now() + interval '30 days'),

  sent_by    uuid,
  sent_at    timestamptz NOT NULL DEFAULT now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,

  -- The workshop recording an approval the customer gave over the phone or on WhatsApp. Evidence is
  -- required with it — who took it, through which channel, when, and the file if there is one —
  -- because an approval nobody can produce later is not an approval, it is an assertion.
  on_behalf  boolean NOT NULL DEFAULT false,
  evidence   jsonb   NOT NULL DEFAULT '{}'::jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_approval_rounds_token
  ON qvm_new_apps.quotation_approval_rounds (access_token);
-- One open round per audience per order. A second "send to the workshop" while the first is still
-- out would put two versions of the same question in front of the same person.
CREATE UNIQUE INDEX IF NOT EXISTS uq_approval_rounds_open
  ON qvm_new_apps.quotation_approval_rounds (quotation_id, audience)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS qvm_new_apps.quotation_approval_items (
  approval_item_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  approval_round_id bigint NOT NULL
                      REFERENCES qvm_new_apps.quotation_approval_rounds (approval_round_id) ON DELETE CASCADE,
  quotation_item_id bigint NOT NULL,
  -- The vendor line this was priced from. The purchase order follows it: سعر الجملة and the vendor
  -- who gave it travel together, so approving a price is also choosing who it is bought from.
  cost_id           bigint,
  wholesale_price   numeric(12,2),
  customer_price    numeric(12,2),
  quantity          integer,
  -- The option the approver picked, when the line was sent with alternatives. Choosing one does NOT
  -- create a new item — the line keeps its identity and records which of the offers was accepted.
  chosen_alternative_id bigint
                      REFERENCES qvm_new_apps.quotation_vendor_item_alternatives (alternative_id),
  decision          text NOT NULL DEFAULT 'pending'
                      CHECK (decision IN ('pending', 'approved', 'cancelled')),
  reason            text,
  decided_at        timestamptz,
  UNIQUE (approval_round_id, quotation_item_id)
);

CREATE INDEX IF NOT EXISTS ix_approval_items_round
  ON qvm_new_apps.quotation_approval_items (approval_round_id);

GRANT ALL ON qvm_new_apps.quotation_approval_rounds,
             qvm_new_apps.quotation_approval_items TO service_role;

-- ── Sending ───────────────────────────────────────────────────────────────────────────────────
--
-- Both audiences can go at once — that is what the send dialog's two switches mean — but they are
-- separate rounds, because they are approvals of different numbers by different people and either
-- can come back without the other.
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
    INSERT INTO qvm_new_apps.quotation_approval_items
      (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity)
    SELECT v_round, qi.quotation_item_id, best.cost_id, best.cost, best.agency_price, qi.quantity
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN LATERAL (
        SELECT qvi.cost_id, qvi.cost, qvi.agency_price
          FROM qvm_new_apps.quotation_vendor_items qvi
         WHERE qvi.quotation_item_id = qi.quotation_item_id
           AND qvi.cost IS NOT NULL AND qvi.cost > 0
         ORDER BY qvi.best_cost DESC, qvi.cost ASC
         LIMIT 1
      ) best ON true
     WHERE qi.quotation_id = p_quotation_id
       AND (p_item_ids IS NULL OR qi.quotation_item_id = ANY(p_item_ids))
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
          quantity        = EXCLUDED.quantity;

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

-- ── Reading, as whoever is holding the link ───────────────────────────────────────────────────
--
-- The audience gate lives here. A client round never returns a wholesale figure at all — not hidden
-- in the payload for the page to omit, absent from it — because a price the customer must not see
-- is not something to be trusted to a CSS class.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_approval_round_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM qvm_new_apps.quotation_approval_rounds
   WHERE access_token = p_token;

  IF r IS NULL THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF now() > r.token_expires_at THEN RETURN jsonb_build_object('status', 'expired'); END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'approval_round_id', r.approval_round_id,
    'audience',    r.audience,
    'round_status', r.status,
    'total_amount', r.total_amount,
    'order', (SELECT jsonb_build_object(
                'quotation_id', q.quotation_id,
                'order_number', q.order_number,
                'plate_number', q.plate_number,
                'created_at',   q.created_at)
                FROM qvm_new_apps.quotations q WHERE q.quotation_id = r.quotation_id),
    'customer', (SELECT jsonb_build_object(
                   'end_customer_id', ec.end_customer_id,
                   'customer_kind',   ec.customer_kind,
                   'name', COALESCE(ec.name, ic.name))
                   FROM qvm_new_apps.end_customers ec
                   LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = ec.insurance_company_id
                  WHERE ec.end_customer_id = r.end_customer_id),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'approval_item_id',  ai.approval_item_id,
               'quotation_item_id', ai.quotation_item_id,
               'part_number',       qi.part_number,
               'part_description',  qi.part_description,
               'quantity',          ai.quantity,
               'delivery_days',     qvi.sla,
               -- The one number this audience is entitled to, under one name either way, so the
               -- page renders one column and cannot show the wrong one by picking the wrong key.
               'unit_price', CASE WHEN r.audience = 'workshop'
                                  THEN ai.wholesale_price ELSE ai.customer_price END,
               -- Reference only, and only for the workshop: they are the ones who will have to put
               -- this figure to the customer.
               'customer_price_reference',
                 CASE WHEN r.audience = 'workshop' THEN ai.customer_price END,
               'decision',   ai.decision,
               'reason',     ai.reason,
               'chosen_alternative_id', ai.chosen_alternative_id,
               -- "This line has options — pick one." Priced at the same basis as the line itself.
               'options', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'alternative_id', a.alternative_id,
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
                  WHERE a.cost_id = ai.cost_id
                    -- The workshop sees every alternative the vendor offered; the customer sees only
                    -- the ones the vendor marked as theirs to see.
                    AND (r.audience = 'workshop' OR a.visible_to_workshop)), '[]'::jsonb)
             ) ORDER BY ai.quotation_item_id)
        FROM qvm_new_apps.quotation_approval_items ai
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ai.quotation_item_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = ai.cost_id
       WHERE ai.approval_round_id = r.approval_round_id), '[]'::jsonb));
END;
$function$;

-- ── Answering ─────────────────────────────────────────────────────────────────────────────────
--
-- Per-line: approve, cancel with a reason, or pick one of the options. Then the round as a whole.
-- Split in two because that is how the screens work — the approver ticks their way down the list
-- and commits once at the bottom.
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
                        AND a.cost_id = ai.cost_id));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.submit_approval_round(
  p_token uuid, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round    bigint;
  v_audience text;
  v_status   text;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected', 'revision_requested') THEN
    RAISE EXCEPTION 'Unknown decision: %', p_decision;
  END IF;

  SELECT r.approval_round_id, r.audience, r.status INTO v_round, v_audience, v_status
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.access_token = p_token AND now() <= r.token_expires_at;

  IF v_round IS NULL THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'already_resolved', 'round_status', v_status);
  END IF;

  -- Anything the approver did not explicitly cancel is approved. Ticking every line to say yes
  -- when yes is the whole point of pressing the button is work for its own sake.
  UPDATE qvm_new_apps.quotation_approval_items
     SET decision = 'approved', decided_at = now()
   WHERE approval_round_id = v_round AND decision = 'pending'
     AND p_decision = 'approved';

  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET status = p_decision,
         decided_by = auth.uid(),
         decided_at = now(),
         decision_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         total_amount = (
           SELECT COALESCE(SUM(COALESCE(CASE WHEN v_audience = 'workshop'
                                             THEN ai.wholesale_price ELSE ai.customer_price END, 0)
                               * COALESCE(ai.quantity, 1)), 0)
             FROM qvm_new_apps.quotation_approval_items ai
            WHERE ai.approval_round_id = v_round AND ai.decision = 'approved')
   WHERE r.approval_round_id = v_round;

  RETURN jsonb_build_object('status', 'success', 'round_status', p_decision);
END;
$function$;

-- The workshop recording the customer's answer, taken over the phone or on WhatsApp. Same effect on
-- the round as the customer pressing the button themselves, with the difference written down.
CREATE OR REPLACE FUNCTION qvm_new_apps.record_client_approval_on_behalf(
  p_quotation_id bigint, p_evidence jsonb, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_team()
          OR EXISTS (SELECT 1 FROM qvm_new_apps.workshop_users_for_quotation(p_quotation_id) w
                      WHERE w.user_id = auth.uid())) THEN
    RAISE EXCEPTION 'Not allowed to record an approval for this order';
  END IF;

  IF COALESCE(btrim(p_evidence->>'channel'), '') = ''
     OR COALESCE(btrim(p_evidence->>'recorded_by_name'), '') = '' THEN
    -- An approval nobody can produce later is an assertion, not an approval.
    RAISE EXCEPTION 'Recording an approval on the customer''s behalf needs who took it and how';
  END IF;

  SELECT r.approval_round_id INTO v_round
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = p_quotation_id AND r.audience = 'client' AND r.status = 'pending';

  IF v_round IS NULL THEN
    RETURN jsonb_build_object('status', 'error',
                              'message', 'This order has not been sent to the customer');
  END IF;

  UPDATE qvm_new_apps.quotation_approval_items
     SET decision = 'approved', decided_at = now()
   WHERE approval_round_id = v_round AND decision = 'pending';

  UPDATE qvm_new_apps.quotation_approval_rounds
     SET status = 'approved', decided_by = auth.uid(), decided_at = now(),
         on_behalf = true, evidence = COALESCE(p_evidence, '{}'::jsonb),
         decision_note = NULLIF(btrim(COALESCE(p_note, '')), '')
   WHERE approval_round_id = v_round;

  RETURN jsonb_build_object('status', 'success', 'approval_round_id', v_round);
END;
$function$;

-- What the pricing page draws its per-line chips from: where each audience has got to.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_approval_state(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'approval_round_id', r.approval_round_id,
             'audience',     r.audience,
             'status',       r.status,
             'total_amount', r.total_amount,
             'on_behalf',    r.on_behalf,
             'evidence',     r.evidence,
             'sent_at',      r.sent_at,
             'decided_at',   r.decided_at,
             'access_token', r.access_token,
             'items', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'quotation_item_id', ai.quotation_item_id,
                        'decision', ai.decision,
                        'reason',   ai.reason,
                        'chosen_alternative_id', ai.chosen_alternative_id))
                 FROM qvm_new_apps.quotation_approval_items ai
                WHERE ai.approval_round_id = r.approval_round_id), '[]'::jsonb))
           ORDER BY r.approval_round_id)
      FROM qvm_new_apps.quotation_approval_rounds r
     WHERE r.quotation_id = p_quotation_id), '[]'::jsonb);
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_quotation_for_approval(p_quotation_id bigint, p_audiences text[], p_item_ids bigint[] DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.send_quotation_for_approval(p_quotation_id, p_audiences, p_item_ids); $$;

CREATE OR REPLACE FUNCTION public.get_approval_round_by_token(p_token uuid)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.get_approval_round_by_token(p_token); $$;

CREATE OR REPLACE FUNCTION public.decide_approval_items(p_token uuid, p_decisions jsonb)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.decide_approval_items(p_token, p_decisions); $$;

CREATE OR REPLACE FUNCTION public.submit_approval_round(p_token uuid, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.submit_approval_round(p_token, p_decision, p_note); $$;

CREATE OR REPLACE FUNCTION public.record_client_approval_on_behalf(p_quotation_id bigint, p_evidence jsonb, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.record_client_approval_on_behalf(p_quotation_id, p_evidence, p_note); $$;

CREATE OR REPLACE FUNCTION public.get_quotation_approval_state(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.get_quotation_approval_state(p_quotation_id); $$;

REVOKE ALL ON FUNCTION public.send_quotation_for_approval(bigint, text[], bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_approval_round_by_token(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_approval_items(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_approval_round(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_client_approval_on_behalf(bigint, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quotation_approval_state(bigint) FROM PUBLIC;

-- anon reaches the three token functions and nothing else: the customer has no login, and the link
-- is the whole of their credential. Each of them resolves the token itself and answers not_found to
-- anyone without a live one.
GRANT EXECUTE ON FUNCTION public.get_approval_round_by_token(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.decide_approval_items(uuid, jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.submit_approval_round(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.send_quotation_for_approval(bigint, text[], bigint[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_client_approval_on_behalf(bigint, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_quotation_approval_state(bigint) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION qvm_new_apps.send_quotation_for_approval(bigint, text[], bigint[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_approval_round_by_token(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.decide_approval_items(uuid, jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.submit_approval_round(uuid, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.record_client_approval_on_behalf(bigint, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_quotation_approval_state(bigint) TO authenticated, service_role;
