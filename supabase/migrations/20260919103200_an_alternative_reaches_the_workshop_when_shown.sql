-- An alternative reaches the workshop when the pricing team shows it, and the pricing team can
-- answer for the workshop.
--
-- Three things. The vendor's alternatives are the pricing team's material: the workshop sees only
-- the ones the pricing team marked visible, in whichever view (the audience no longer bypasses the
-- flag). When the workshop picks an alternative and approves, that pick becomes the line's choice,
-- so the confirmed item and the PO follow it. And the pricing team can record the workshop's
-- approval on its behalf — by phone, in person — at the price and the alternative currently picked
-- on the pricing page, with who took it and how, exactly as the workshop records the customer's.
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
  v_qid      bigint;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected', 'revision_requested') THEN
    RAISE EXCEPTION 'Unknown decision: %', p_decision;
  END IF;

  SELECT r.approval_round_id, r.audience, r.status, r.quotation_id INTO v_round, v_audience, v_status, v_qid
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

  -- The workshop's approval IS the confirmation. The lines it said yes to become confirmed items on
  -- a confirmed order — the rows a purchase order is built on — exactly as the cart confirmation
  -- would have made them.
  IF v_audience = 'workshop' AND p_decision = 'approved' THEN
    -- The option the workshop picked becomes the line's choice, so the confirmed item and the
    -- purchase order follow the part the workshop actually said yes to.
    UPDATE qvm_new_apps.quotation_vendor_items qvi
       SET chosen_alternative_id = ai.chosen_alternative_id, updated_at = now()
      FROM qvm_new_apps.quotation_approval_items ai
     WHERE ai.approval_round_id = v_round AND ai.decision = 'approved'
       AND ai.chosen_alternative_id IS NOT NULL AND qvi.cost_id = ai.cost_id;
    PERFORM qvm_new_apps.confirm_approved_lines(v_qid);
  END IF;

  RETURN jsonb_build_object('status', 'success', 'round_status', p_decision);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.record_workshop_approval_on_behalf(
  p_quotation_id bigint, p_evidence jsonb, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint;
  v_token uuid;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can record an approval for the workshop';
  END IF;

  IF COALESCE(btrim(p_evidence->>'channel'), '') = ''
     OR COALESCE(btrim(p_evidence->>'recorded_by_name'), '') = '' THEN
    RAISE EXCEPTION 'Recording an approval on the workshop''s behalf needs who took it and how';
  END IF;

  SELECT r.approval_round_id, r.access_token INTO v_round, v_token
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = p_quotation_id AND r.audience = 'workshop' AND r.status = 'pending'
   ORDER BY r.approval_round_id DESC LIMIT 1;

  IF v_round IS NULL THEN
    RETURN jsonb_build_object('status', 'error',
                              'message', 'This order has not been sent to the workshop');
  END IF;

  -- The workshop said yes to what the pricing page shows: the line as picked there — the
  -- alternative the pricing team chose on the vendor's offer, or the original.
  UPDATE qvm_new_apps.quotation_approval_items ai
     SET chosen_alternative_id = qvi.chosen_alternative_id
    FROM qvm_new_apps.quotation_vendor_items qvi
   WHERE ai.approval_round_id = v_round AND ai.decision = 'pending'
     AND qvi.cost_id = ai.cost_id;

  -- The token's expiry is for the mailed link; the close below goes through it, so a link nobody
  -- used must not have aged out from under the pricing team.
  UPDATE qvm_new_apps.quotation_approval_rounds
     SET on_behalf = true, evidence = COALESCE(p_evidence, '{}'::jsonb),
         token_expires_at = GREATEST(token_expires_at, now() + interval '1 day')
   WHERE approval_round_id = v_round;

  -- The same close as the workshop's own button: every pending line approved, the round approved,
  -- the confirmed items created.
  RETURN qvm_new_apps.submit_approval_round(v_token, 'approved', p_note)
         || jsonb_build_object('approval_round_id', v_round);
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.record_workshop_approval_on_behalf(bigint, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.record_workshop_approval_on_behalf(bigint, jsonb, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_workshop_approval_on_behalf(
  p_quotation_id bigint, p_evidence jsonb, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.record_workshop_approval_on_behalf(p_quotation_id, p_evidence, p_note) $$;
REVOKE ALL ON FUNCTION public.record_workshop_approval_on_behalf(bigint, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_workshop_approval_on_behalf(bigint, jsonb, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 6 $$;
