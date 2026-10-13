-- The customer's approval page shows the whole quotation the way the design lays it out: a header
-- with the customer, claim, vehicle, plate and workshop; the agreed discount and the brand it is
-- agreed for; who answered and when; how many requests the customer has open; lines added by the
-- Qparts team after the workshop raised the order marked as proposed; and the customer's own
-- reference number (their claim / file number), which they can confirm or correct before answering.

alter table qvm_new_apps.quotation_approval_rounds
  add column if not exists customer_reference text;
comment on column qvm_new_apps.quotation_approval_rounds.customer_reference is
  'The approver''s own reference for this request (an insurer''s claim number), entered on the approval page.';

-- The reference, by link or by session, while the request is open.
create or replace function qvm_new_apps.set_approval_reference(p_token uuid, p_reference text)
returns jsonb language plpgsql security definer set search_path to 'qvm_new_apps', 'public' as $$
declare v_round bigint;
begin
  select r.approval_round_id into v_round from qvm_new_apps.quotation_approval_rounds r
   where r.access_token = p_token and now() <= r.token_expires_at and r.status = 'pending';
  if v_round is null then return jsonb_build_object('status', 'not_found'); end if;
  update qvm_new_apps.quotation_approval_rounds
     set customer_reference = nullif(btrim(coalesce(p_reference, '')), '')
   where approval_round_id = v_round;
  return jsonb_build_object('status', 'success');
end $$;

create or replace function qvm_new_apps.set_approval_reference_as_user(p_quotation_id bigint, p_reference text)
returns jsonb language plpgsql security definer set search_path to 'qvm_new_apps', 'public' as $$
declare
  v_round bigint := qvm_new_apps.approval_round_for_user(p_quotation_id, 'client');
  v_token uuid;
begin
  if v_round is null then raise exception 'This order was not sent to you for approval'; end if;
  select access_token into v_token from qvm_new_apps.quotation_approval_rounds where approval_round_id = v_round;
  return qvm_new_apps.set_approval_reference(v_token, p_reference);
end $$;

grant execute on function qvm_new_apps.set_approval_reference(uuid, text) to anon, authenticated, service_role;
grant execute on function qvm_new_apps.set_approval_reference_as_user(bigint, text) to authenticated, service_role;

-- The view: header facts, the answer, the open-request count, the agreed brand.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_approval_round_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
    'expires_at', r.token_expires_at,
    'sent_at',    r.sent_at,
    'decided_at', r.decided_at,
    'decided_by_name', (SELECT ud.user_name FROM qvm_new_apps.user_data ud WHERE ud.user_id = r.decided_by),
    'decision_note', r.decision_note,
    'customer_reference', r.customer_reference,
    -- The vehicle and the workshop branch the order came from, as its first line names them.
    'vehicle', (SELECT jsonb_build_object('brand', ld.list_data, 'model', qi.model, 'year', qi.year, 'vin', qi.vin)
                  FROM qvm_new_apps.quotation_items qi
                  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
                 WHERE qi.quotation_id = r.quotation_id
                 ORDER BY (qi.main_brand IS NULL), qi.quotation_item_id LIMIT 1),
    'workshop', (SELECT cb.branch_name FROM qvm_new_apps.quotation_items qi
                   JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
                  WHERE qi.quotation_id = r.quotation_id ORDER BY qi.quotation_item_id LIMIT 1),
    -- How many of this customer's quotations are waiting on them, the latest request per order.
    'open_requests', (SELECT count(*) FROM qvm_new_apps.quotation_approval_rounds o2
                       WHERE r.audience = 'client' AND o2.audience = 'client'
                         AND o2.end_customer_id = r.end_customer_id AND o2.status = 'pending'
                         AND o2.approval_round_id = (SELECT max(o3.approval_round_id) FROM qvm_new_apps.quotation_approval_rounds o3
                                                      WHERE o3.quotation_id = o2.quotation_id AND o3.audience = 'client')),
    -- How the offer was put to the customer: what the page shows, the message, the claim and the files.
    'offer', (SELECT jsonb_build_object(
                'show_part_number', o.show_part_number, 'show_alternatives', o.show_alternatives,
                'show_discount', o.show_discount, 'show_lead_time', o.show_lead_time,
                'show_notes', o.show_notes, 'show_photos', o.show_photos,
                'discount_mode', o.discount_mode, 'validity_days', o.validity_days,
                'base_discount', o.base_discount,
                -- The brand an agreed rate was agreed for: the order's car brand.
                'agreed_brand', CASE WHEN o.discount_mode = 'agreed' THEN (
                   SELECT ld.list_data FROM qvm_new_apps.quotation_items qi
                     JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
                    WHERE qi.quotation_id = r.quotation_id ORDER BY qi.quotation_item_id LIMIT 1) END,
                'claim_number', o.claim_number, 'message', o.message, 'subject', o.subject,
                'attachments', o.attachments, 'document_url', o.document_url, 'sent_at', o.sent_at,
                'total_before_discount', (SELECT COALESCE(SUM(COALESCE(ai.price_before_discount, ai.customer_price, 0) * COALESCE(ai.quantity, 1)), 0)
                                            FROM qvm_new_apps.quotation_approval_items ai
                                           WHERE ai.approval_round_id = r.approval_round_id AND ai.decision <> 'cancelled'))
                FROM qvm_new_apps.quotation_approval_offers o
               WHERE o.approval_round_id = r.approval_round_id AND r.audience = 'client'),
    'items', qvm_new_apps.approval_lines(r.quotation_id, r.audience, r.approval_round_id, r.status));
END;
$function$;

-- The lines: proposals marked.
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_lines(p_quotation_id bigint, p_audience text, p_round_id bigint, p_round_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               -- NULL for a line never put to this audience: there is nothing to answer on it.
               'approval_item_id',  li.approval_item_id,
               'quotation_item_id', qi.quotation_item_id,
               'part_number',       CASE WHEN p_audience = 'client' AND off.show_part_number IS FALSE THEN NULL ELSE qi.part_number END,
               'part_description',  qi.part_description,
               -- The line itself, so the table this feeds can stand in for the order's item list:
               -- where the part is in its life, its photos, how many notes are on it, its class.
               'item_status',       ldst.list_data,
               'item_status_id',    qi.item_status,
               'part_photo',        CASE WHEN p_audience = 'client' AND off.show_photos IS FALSE THEN NULL ELSE qi.part_photo END,
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
               'delivery_days',     CASE WHEN p_audience = 'client' AND off.show_lead_time IS FALSE THEN NULL
                                 WHEN p_audience = 'client' AND li.lead_days IS NOT NULL THEN li.lead_days::text
                                 ELSE COALESCE(qvi.sla, bq.sla) END,
               -- A customer round sent as a prepared offer: the price before its discount, the
               -- discount, and the buyer's note — each only when the offer shows it.
               'price_before_discount', CASE WHEN p_audience = 'client' AND off.show_discount THEN li.price_before_discount END,
               'discount_percent',      CASE WHEN p_audience = 'client' AND off.show_discount THEN li.discount_percent END,
               'customer_note',         CASE WHEN p_audience = 'client' AND off.show_notes IS NOT FALSE THEN li.customer_note END,
               -- A line the Qparts team added after the workshop raised the order: the customer is
               -- told it is a proposal, by whom and when.
               'proposed_by', CASE WHEN p_audience = 'client'
                                    AND EXISTS (SELECT 1 FROM qvm_new_apps.user_data pu WHERE pu.user_id = qi.created_by AND pu.user_type = 185)
                                    AND qi.created_by IS DISTINCT FROM (SELECT f.created_by FROM qvm_new_apps.quotation_items f
                                                                         WHERE f.quotation_id = qi.quotation_id ORDER BY f.quotation_item_id LIMIT 1)
                                   THEN (SELECT pu.user_name FROM qvm_new_apps.user_data pu WHERE pu.user_id = qi.created_by) END,
               'proposed_at', CASE WHEN p_audience = 'client' THEN qi.created_at END,
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
                 CASE WHEN li.approval_item_id IS NOT NULL AND lr.status = 'pending' THEN li.chosen_alternative_id
                      ELSE (SELECT a.alternative_id FROM qvm_new_apps.quotation_vendor_item_alternatives a
                             WHERE a.alternative_id = COALESCE(qvi.chosen_alternative_id, bq.chosen_alternative_id)
                               AND a.visible_to_workshop) END,
               'options', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'alternative_id', a.alternative_id,
                          'source',         a.source,
                          'part_number',    a.part_number,
                          'brand_class_name', bc.list_data,
                          'brand_name',     br.list_data,
                          'origin', COALESCE(oc.name_ar, oc.name_en),
                          'unit_price',     CASE WHEN p_audience = 'client' AND li.discount_percent IS NOT NULL AND a.unit_price IS NOT NULL
                                               THEN round(a.unit_price * (1 - li.discount_percent / 100), 2)
                                               ELSE a.unit_price END,
                          'price_before_discount', CASE WHEN p_audience = 'client' AND off.show_discount THEN a.unit_price END,
                          'available_quantity', a.available_quantity,
                          'delivery_days',  a.delivery_days,
                          'note',           a.note,
                          'photos',         a.photos) ORDER BY a.alternative_id)
                   FROM qvm_new_apps.quotation_vendor_item_alternatives a
                   LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                   LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                   LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                  WHERE (a.cost_id = COALESCE(li.cost_id, bq.cost_id)
                         OR (a.source = 'qparts' AND a.quotation_item_id = qi.quotation_item_id))
                    AND a.visible_to_workshop
                    -- The customer sees only the alternatives the offer shows them.
                    AND (p_audience <> 'client' OR off.show_alternatives IS NOT FALSE)
                    AND (p_audience <> 'client' OR li.shown_alternative_ids IS NULL OR a.alternative_id = ANY(li.shown_alternative_ids))), '[]'::jsonb)
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
        LEFT JOIN qvm_new_apps.quotation_approval_offers off ON off.approval_round_id = li.approval_round_id
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

notify pgrst, 'reload schema';
