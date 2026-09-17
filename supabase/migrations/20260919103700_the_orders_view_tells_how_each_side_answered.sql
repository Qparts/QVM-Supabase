-- The order's view tells how each side answered.
--
-- An approval recorded on the customer's behalf carried who took it, how, when and against what
-- reference — and the view never showed any of it. Each audience's latest round now comes back with
-- its decision, when it was sent and answered, by whom, and the evidence when it was answered for
-- them, so the workshop reads the customer's approval on the order it belongs to.
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_round_summary(p_quotation_id bigint, p_audience text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'approval_round_id', r.approval_round_id,
           'status',        r.status,
           'total_amount',  r.total_amount,
           'sent_at',       r.sent_at,
           'sent_by_name',  sb.user_name,
           'decided_at',    r.decided_at,
           'decided_by_name', db.user_name,
           'on_behalf',     COALESCE(r.on_behalf, false),
           'evidence',      COALESCE(r.evidence, '{}'::jsonb),
           'decision_note', r.decision_note)
    FROM qvm_new_apps.quotation_approval_rounds r
    LEFT JOIN qvm_new_apps.user_data sb ON sb.user_id = r.sent_by
    LEFT JOIN qvm_new_apps.user_data db ON db.user_id = r.decided_by
   WHERE r.quotation_id = p_quotation_id AND r.audience = p_audience
   ORDER BY r.approval_round_id DESC
   LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.approval_round_summary(bigint, text) FROM PUBLIC;

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
                                 ORDER BY c.approval_round_id DESC LIMIT 1),
        'decisions', jsonb_build_object(
          'workshop', qvm_new_apps.approval_round_summary(p_quotation_id, 'workshop'),
          'client',   qvm_new_apps.approval_round_summary(p_quotation_id, 'client')));
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
                             ORDER BY c.approval_round_id DESC LIMIT 1),
    -- How each audience answered, with the evidence when somebody answered for them.
    'decisions', jsonb_build_object(
      'workshop', qvm_new_apps.approval_round_summary(p_quotation_id, 'workshop'),
      'client',   qvm_new_apps.approval_round_summary(p_quotation_id, 'client')));
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 11 $$;
