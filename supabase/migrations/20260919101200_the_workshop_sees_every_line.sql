-- The workshop sees every line, and confirms only the ones put to it.
--
-- The approval view read one round — the latest — and showed only its lines. Send round 1 with three
-- parts, round 2 with two more, and the workshop's screen forgets the first three: to them a part
-- confirmed last week now looks like it was never sent, while the pricing page, counting any
-- appearance in any round as "sent", refuses to send it again. Order COMW4's oil seal fell into
-- exactly that gap.
--
-- Now the view is the ORDER's lines — all of them — and each line says where it stands with this
-- audience: never sent, waiting in the open request, confirmed earlier, cancelled earlier, or from a
-- round that came back for a better price. Only lines in the currently open request are actionable;
-- the rest are read-only context, which is what a workshop needs to judge the ones it is being asked
-- about. The audience price rule is unchanged: the customer round returns customer prices only.
--
-- Decisions and submit still work on the one pending round per audience (the unique index sees to
-- that), so nothing about answering changes — only what the screen shows around the answer.

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
               -- NULL for a line never put to this audience: there is nothing to answer on it.
               'approval_item_id',  li.approval_item_id,
               'quotation_item_id', qi.quotation_item_id,
               'part_number',       qi.part_number,
               'part_description',  qi.part_description,
               'quantity',          COALESCE(li.quantity, qi.quantity),
               'delivery_days',     COALESCE(qvi.sla, bq.sla),
               -- The one number this audience is entitled to, under one name either way. From the
               -- round's snapshot when the line was sent; from the live order when it was not.
               'unit_price', CASE WHEN r.audience = 'workshop'
                                  THEN COALESCE(li.wholesale_price, COALESCE(bch.unit_price, bq.cost))
                                  ELSE COALESCE(li.customer_price, NULLIF(qi.price_before_vat, 0), bq.agency_price) END,
               'customer_price_reference',
                 CASE WHEN r.audience = 'workshop'
                      THEN COALESCE(li.customer_price, NULLIF(qi.price_before_vat, 0), bq.agency_price) END,
               -- Where this line stands with THIS audience, whichever round it was in.
               'sent',              li.approval_item_id IS NOT NULL,
               'line_round_id',     li.approval_round_id,
               'line_round_status', lr.status,
               -- Only a line in the currently open request can be answered.
               'actionable',        li.approval_round_id = r.approval_round_id AND r.status = 'pending',
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
                    AND (r.audience = 'workshop' OR a.visible_to_workshop)), '[]'::jsonb)
             ) ORDER BY qi.quotation_item_id)
        FROM qvm_new_apps.quotation_items qi
        -- The line's most recent appearance in any round for this audience.
        LEFT JOIN LATERAL (
          SELECT ai.*
            FROM qvm_new_apps.quotation_approval_items ai
            JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
           WHERE ai.quotation_item_id = qi.quotation_item_id
             AND ar.quotation_id = r.quotation_id
             AND ar.audience = r.audience
           ORDER BY ai.approval_round_id DESC
           LIMIT 1
        ) li ON true
        LEFT JOIN qvm_new_apps.quotation_approval_rounds lr ON lr.approval_round_id = li.approval_round_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = li.cost_id
        -- For a line never sent: the offer it would be priced from today.
        LEFT JOIN LATERAL (
          SELECT v.cost_id, v.cost, v.agency_price, v.sla, v.chosen_alternative_id
            FROM qvm_new_apps.quotation_vendor_items v
           WHERE v.quotation_item_id = qi.quotation_item_id
             AND v.cost IS NOT NULL AND v.cost > 0
           ORDER BY v.best_cost DESC, v.cost ASC
           LIMIT 1
        ) bq ON true
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives bch ON bch.alternative_id = bq.chosen_alternative_id
       WHERE qi.quotation_id = r.quotation_id
         -- Suggested parts are not part of the order until somebody says so; cancelled ones are gone.
         AND qi.item_status NOT IN (
           SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
            WHERE ld.list_id = 3
              AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))), '[]'::jsonb));
END;
$function$;
