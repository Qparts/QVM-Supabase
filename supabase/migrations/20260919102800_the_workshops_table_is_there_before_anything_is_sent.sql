-- The workshop's table is there before anything is sent.
--
-- The approval panel answered "not sent yet" whenever the order had no workshop round, and the parts
-- a vendor suggested — which the workshop decides on regardless — were drawn only inside the full
-- panel. So a suggested part could not be approved until the pricing team happened to ask for a
-- price confirmation, which is a different question. Now a workshop user opening their order always
-- gets the table: every line as not-sent and nothing answerable until a round exists, and the
-- suggested parts with their buttons whenever there are any.

-- The order's lines as one audience is entitled to see them, whether or not a round exists.
--
-- Pulled out of get_approval_round_by_token so the same query can answer two questions: "what is in
-- this round" (p_round_id set) and "what does this order look like to the workshop before anything
-- was sent" (p_round_id NULL — every line reads not-sent, nothing actionable). One query, one audience
-- rule: the customer never receives a wholesale figure from it.
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
               'quantity',          COALESCE(li.quantity, qi.quantity),
               'delivery_days',     COALESCE(qvi.sla, bq.sla),
               -- The one number this audience is entitled to, under one name either way. From the
               -- round's snapshot when the line was sent; from the live order when it was not.
               'unit_price', CASE WHEN p_audience = 'workshop'
                                  THEN COALESCE(li.wholesale_price, COALESCE(bch.unit_price, bq.cost))
                                  ELSE COALESCE(li.customer_price, NULLIF(qi.price_before_vat, 0), bq.agency_price) END,
               'customer_price_reference',
                 CASE WHEN p_audience = 'workshop'
                      THEN COALESCE(li.customer_price, NULLIF(qi.price_before_vat, 0), bq.agency_price) END,
               -- Where this line stands with THIS audience, whichever round it was in.
               'sent',              li.approval_item_id IS NOT NULL,
               'line_round_id',     li.approval_round_id,
               'line_round_status', lr.status,
               -- Only a line in the currently open request can be answered.
               'actionable',        li.approval_round_id = p_round_id AND p_round_status = 'pending',
               'decision',          COALESCE(li.decision, 'pending'),
               'reason',            li.reason,
               'chosen_alternative_id', li.chosen_alternative_id,
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
                  WHERE a.cost_id = COALESCE(li.cost_id, bq.cost_id)
                    AND (p_audience = 'workshop' OR a.visible_to_workshop)), '[]'::jsonb)
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
          SELECT v.cost_id, v.cost, v.agency_price, v.sla, v.chosen_alternative_id
            FROM qvm_new_apps.quotation_vendor_items v
           WHERE v.quotation_item_id = qi.quotation_item_id
             AND v.cost IS NOT NULL AND v.cost > 0
           ORDER BY (v.cost_id = qi.selected_cost_id) DESC NULLS LAST, v.best_cost DESC, v.cost ASC
           LIMIT 1
        ) bq ON true
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives bch ON bch.alternative_id = bq.chosen_alternative_id
       WHERE qi.quotation_id = p_quotation_id
         -- Suggested parts are not part of the order until somebody says so; cancelled ones are gone.
         AND qi.item_status NOT IN (
           SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
            WHERE ld.list_id = 3
              AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))), '[]'::jsonb);
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.approval_lines(bigint, text, bigint, text) FROM PUBLIC;

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
    'items', qvm_new_apps.approval_lines(r.quotation_id, r.audience, r.approval_round_id, r.status));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_approval_view(p_quotation_id bigint, p_audience text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint;
  v_token uuid;
  v_view  jsonb;
BEGIN
  IF p_audience NOT IN ('workshop', 'client') THEN
    RAISE EXCEPTION 'Unknown approval audience: %', p_audience;
  END IF;

  v_round := qvm_new_apps.approval_round_for_user(p_quotation_id, p_audience);
  IF v_round IS NULL THEN
    -- No round yet. The workshop still sees its order: every line as not-sent, nothing answerable,
    -- and — the reason this exists — the parts a vendor suggested, which the workshop decides on
    -- whether or not the pricing team has asked for a price confirmation. The customer sees nothing
    -- before being sent something; a quotation not yet put to them is not theirs to read.
    IF p_audience = 'workshop'
       AND (qvm_new_apps.is_qparts_team()
            OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id))) THEN
      RETURN jsonb_build_object(
        'status', 'ok',
        'audience', 'workshop',
        'round_status', NULL,
        'total_amount', NULL,
        'order', (SELECT jsonb_build_object('quotation_id', q.quotation_id, 'order_number', q.order_number,
                                            'plate_number', q.plate_number, 'created_at', q.created_at)
                    FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id),
        'customer', (SELECT jsonb_build_object('end_customer_id', ec.end_customer_id, 'customer_kind', ec.customer_kind,
                                               'name', COALESCE(ec.name, ic.name))
                       FROM qvm_new_apps.quotations q
                       JOIN qvm_new_apps.end_customers ec ON ec.end_customer_id = q.end_customer_id
                       LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = ec.insurance_company_id
                      WHERE q.quotation_id = p_quotation_id),
        'items', qvm_new_apps.approval_lines(p_quotation_id, 'workshop', NULL, NULL),
        'can_decide', false,
        'can_record_on_behalf', false,
        'client_round_status', NULL);
    END IF;
    RETURN jsonb_build_object('status', 'none');
  END IF;

  -- The token's expiry is for the mailed link. A signed-in user is identified by their session,
  -- so a round they are entitled to does not go dark on them because a link they never used aged
  -- out — the expiry is pushed forward instead. (Which is why this is not STABLE.)
  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET token_expires_at = now() + interval '30 days'
   WHERE r.approval_round_id = v_round AND r.token_expires_at < now();

  SELECT r.access_token INTO v_token
    FROM qvm_new_apps.quotation_approval_rounds r WHERE r.approval_round_id = v_round;

  v_view := qvm_new_apps.get_approval_round_by_token(v_token);
  -- The token itself stays inside: a signed-in user acts through their session, and the page has
  -- no business holding a credential that would also work signed out.
  RETURN v_view || jsonb_build_object(
    'can_decide', (v_view->>'round_status') = 'pending',
    -- A workshop user may also speak for the customer, with evidence. Only while there is a
    -- customer round still open to speak on.
    'can_record_on_behalf', p_audience = 'workshop' AND EXISTS (
       SELECT 1 FROM qvm_new_apps.quotation_approval_rounds c
        WHERE c.quotation_id = p_quotation_id AND c.audience = 'client' AND c.status = 'pending'),
    'client_round_status', (SELECT c.status FROM qvm_new_apps.quotation_approval_rounds c
                             WHERE c.quotation_id = p_quotation_id AND c.audience = 'client'
                             ORDER BY c.approval_round_id DESC LIMIT 1));
END;
$function$;

-- A marker the client can read without a session, so "did this file land" is answerable from the
-- REST API rather than from the branch log.
CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 2 $$;
GRANT EXECUTE ON FUNCTION public.approval_flow_version() TO anon, authenticated;
