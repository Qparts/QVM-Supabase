-- The pricing page reads why a better price was asked for.
--
-- A workshop that presses «طلب تحسين السعر» writes a note; the round stores it as decision_note; the
-- state the pricing page loads did not carry it. So the page could say "the workshop wants a better
-- price" and not what they said — which is the only part the buyer needs to relay to the vendors.
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
             'audience',      r.audience,
             'status',        r.status,
             'total_amount',  r.total_amount,
             'on_behalf',     r.on_behalf,
             'evidence',      r.evidence,
             'decision_note', r.decision_note,
             'sent_at',       r.sent_at,
             'decided_at',    r.decided_at,
             'access_token',  r.access_token,
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
