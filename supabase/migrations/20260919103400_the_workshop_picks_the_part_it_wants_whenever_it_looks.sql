-- The workshop picks the part it wants, whenever it looks.
--
-- Choosing an alternative was possible only inside an open approval request, because the choice
-- lived on the approval item. The workshop looks at its order more often than it is asked to
-- approve, and wants to say "that one" when it sees it. Now the workshop's pick is written to the
-- vendor line itself — the pricing page shows it, the confirmed item and the purchase order follow
-- it — and, when the line is in an open request, onto the approval as well.
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
               -- The choice standing on the line: the approval's when it was sent; before that, the
               -- one on the vendor line — only when the workshop is allowed to see it.
               'chosen_alternative_id',
                 CASE WHEN li.approval_item_id IS NOT NULL THEN li.chosen_alternative_id
                      ELSE (SELECT a.alternative_id FROM qvm_new_apps.quotation_vendor_item_alternatives a
                             WHERE a.alternative_id = bq.chosen_alternative_id AND a.visible_to_workshop) END,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_pick_alternative(
  p_quotation_item_id bigint, p_alternative_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_qid   bigint;
  v_cost  bigint;
  v_part  text;
  v_class bigint;
BEGIN
  SELECT qi.quotation_id INTO v_qid FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_qid IS NULL THEN RAISE EXCEPTION 'Unknown line'; END IF;

  IF NOT (qvm_new_apps.is_qparts_team()
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(v_qid))) THEN
    RAISE EXCEPTION 'Not allowed to choose for this order';
  END IF;

  IF p_alternative_id IS NOT NULL THEN
    -- The option has to be one offered on this line, and one the workshop was shown.
    SELECT a.cost_id INTO v_cost
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      JOIN qvm_new_apps.quotation_vendor_items v ON v.cost_id = a.cost_id
     WHERE a.alternative_id = p_alternative_id
       AND v.quotation_item_id = p_quotation_item_id
       AND a.visible_to_workshop;
    IF v_cost IS NULL THEN RAISE EXCEPTION 'That option is not offered on this line'; END IF;
  ELSE
    -- Back to the original: on the line the order is priced from — the open request's, else the
    -- pricing team's pick, else the best offer.
    SELECT COALESCE(
      (SELECT ai.cost_id FROM qvm_new_apps.quotation_approval_items ai
         JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
        WHERE ai.quotation_item_id = p_quotation_item_id AND ar.audience = 'workshop' AND ar.status = 'pending'
        ORDER BY ai.approval_round_id DESC LIMIT 1),
      (SELECT qi.selected_cost_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id),
      (SELECT v.cost_id FROM qvm_new_apps.quotation_vendor_items v
        WHERE v.quotation_item_id = p_quotation_item_id AND v.cost IS NOT NULL AND v.cost > 0
        ORDER BY v.best_cost DESC, v.cost ASC LIMIT 1)) INTO v_cost;
    IF v_cost IS NULL THEN RETURN jsonb_build_object('status', 'success'); END IF;
  END IF;

  -- The vendor line carries the choice: the pricing page reads it, the PO is written from it.
  UPDATE qvm_new_apps.quotation_vendor_items
     SET chosen_alternative_id = p_alternative_id, updated_at = now()
   WHERE cost_id = v_cost;

  -- The open request, when this line is in one, says the same.
  UPDATE qvm_new_apps.quotation_approval_items ai
     SET chosen_alternative_id = p_alternative_id
    FROM qvm_new_apps.quotation_approval_rounds ar
   WHERE ar.approval_round_id = ai.approval_round_id
     AND ai.quotation_item_id = p_quotation_item_id AND ai.cost_id = v_cost
     AND ar.audience = 'workshop' AND ar.status = 'pending';

  -- A line already confirmed but not yet ordered follows too; an ordered one is the PO's now.
  SELECT COALESCE(a.part_number, qi.alternative_part_number, qi.part_number), COALESCE(a.brand_class, qi.brand_class)
    INTO v_part, v_class
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.alternative_id = p_alternative_id
   WHERE qi.quotation_item_id = p_quotation_item_id;
  UPDATE qvm_new_apps.confirmed_items ci
     SET final_part_number = v_part, final_brand_class = v_class, updated_at = now()
    FROM qvm_new_apps.quotation_items qi
   WHERE ci.quotation_item_id = p_quotation_item_id
     AND qi.quotation_item_id = ci.quotation_item_id AND qi.cost_id IS NULL;

  RETURN jsonb_build_object('status', 'success', 'cost_id', v_cost, 'chosen_alternative_id', p_alternative_id);
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.workshop_pick_alternative(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.workshop_pick_alternative(bigint, bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.workshop_pick_alternative(p_quotation_item_id bigint, p_alternative_id bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.workshop_pick_alternative(p_quotation_item_id, p_alternative_id) $$;
REVOKE ALL ON FUNCTION public.workshop_pick_alternative(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.workshop_pick_alternative(bigint, bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 8 $$;
