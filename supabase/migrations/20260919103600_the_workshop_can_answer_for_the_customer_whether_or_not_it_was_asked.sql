-- The workshop can answer for the customer whether or not it was asked itself.
--
-- The view the workshop gets before any workshop round said the customer had not been asked and
-- nothing could be recorded on their behalf — both hardcoded. The pricing page sends to the customer
-- independently of the workshop, so the customer's request can be open while the workshop's is not;
-- the no-round view now reports the customer round exactly as the with-round view does.
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
        -- The customer may already have been asked — the pricing page sends to either audience
        -- on its own — and the workshop may speak for the customer, with evidence, while that
        -- request is open. Same rule as below; the workshop's own round has nothing to do with it.
        'can_record_on_behalf', EXISTS (
           SELECT 1 FROM qvm_new_apps.quotation_approval_rounds c
            WHERE c.quotation_id = p_quotation_id AND c.audience = 'client' AND c.status = 'pending'),
        'client_round_status', (SELECT c.status FROM qvm_new_apps.quotation_approval_rounds c
                                 WHERE c.quotation_id = p_quotation_id AND c.audience = 'client'
                                 ORDER BY c.approval_round_id DESC LIMIT 1));
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

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 10 $$;
