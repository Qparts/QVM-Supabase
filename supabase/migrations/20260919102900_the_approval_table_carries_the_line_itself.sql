-- The approval table carries the line itself.
--
-- In the order's view the workshop now reads one table, the approval one, instead of the old item
-- list beside it. For that table to replace the other it has to know what the other knew: where
-- each part is in its life (so cancel and add-to-cart know when they apply), its photos, how many
-- notes are on it, its class — and, for the workshop, what the vendor wrote and attached on the
-- offer the line is priced from. Same function, same signature, more on each line.
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
          SELECT v.cost_id, v.cost, v.agency_price, v.sla, v.chosen_alternative_id, v.note, v.files
            FROM qvm_new_apps.quotation_vendor_items v
           WHERE v.quotation_item_id = qi.quotation_item_id
             AND v.cost IS NOT NULL AND v.cost > 0
           ORDER BY (v.cost_id = qi.selected_cost_id) DESC NULLS LAST, v.best_cost DESC, v.cost ASC
           LIMIT 1
        ) bq ON true
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives bch ON bch.alternative_id = bq.chosen_alternative_id
        LEFT JOIN qvm_new_apps.list_data ldst ON ldst.list_data_id = qi.item_status
        LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
       WHERE qi.quotation_id = p_quotation_id
         -- Suggested parts are not part of the order until somebody says so; cancelled ones are gone.
         AND qi.item_status NOT IN (
           SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
            WHERE ld.list_id = 3
              AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))), '[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 3 $$;
