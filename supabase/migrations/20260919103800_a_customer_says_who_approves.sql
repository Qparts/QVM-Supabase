-- A customer says who approves its quotations.
--
-- Two switches on the end customer, both on by default: does the customer approve its quotation
-- prices, does the workshop approve the wholesale prices. The pricing page asks only the sides that
-- are switched on; a line is cleared for purchase once every switched-on side has approved it; and
-- with both switched off a priced line may be bought as it is, no approval asked of anyone.

ALTER TABLE qvm_new_apps.end_customers
  ADD COLUMN IF NOT EXISTS requires_customer_approval boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS requires_workshop_approval boolean NOT NULL DEFAULT true;

CREATE OR REPLACE VIEW qvm_new_apps.v_end_customers AS
SELECT c.end_customer_id, c.customer_kind, c.customer_code, c.tax_number,
       c.contact_person, c.phone, c.email, c.is_active, c.created_at,
       COALESCE(ic.name, c.name) AS name,
       c.insurance_company_id,
       (SELECT count(*) FROM qvm_new_apps.end_customer_branches b
         WHERE b.end_customer_id = c.end_customer_id) AS branch_count,
       (SELECT count(*) FROM qvm_new_apps.end_customer_users u
         WHERE u.end_customer_id = c.end_customer_id) AS user_count,
       c.requires_customer_approval,
       c.requires_workshop_approval
FROM qvm_new_apps.end_customers c
LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = c.insurance_company_id;

-- A new defaulted parameter is a new overload, and two overloads are an ambiguous call: the old
-- signature goes first.
DROP FUNCTION IF EXISTS public.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint);
DROP FUNCTION IF EXISTS qvm_new_apps.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint);

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_end_customer(
  p_end_customer_id bigint  DEFAULT NULL,
  p_customer_kind   text    DEFAULT NULL,
  p_name            text    DEFAULT NULL,
  p_insurance_company_id bigint DEFAULT NULL,
  p_tax_number      text    DEFAULT NULL,
  p_contact_person  text    DEFAULT NULL,
  p_phone           text    DEFAULT NULL,
  p_email           text    DEFAULT NULL,
  -- Who it belongs to, when creating. 'workshop' or 'vendor' plus that thing's id.
  p_owner_kind      text    DEFAULT NULL,
  p_owner_id        bigint  DEFAULT NULL,
  -- Who approves this customer's quotations before a purchase: the customer, the workshop, both
  -- (the default) or neither. NULL on an update leaves the setting alone.
  p_requires_customer_approval boolean DEFAULT NULL,
  p_requires_workshop_approval boolean DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id bigint := p_end_customer_id;
  v_kind text := lower(btrim(COALESCE(p_customer_kind, '')));
BEGIN
  IF v_id IS NULL THEN
    IF v_kind NOT IN ('individual', 'insurance', 'company', 'government') THEN
      RETURN jsonb_build_object('success', false, 'error', 'Pick what kind of customer this is');
    END IF;
    IF p_owner_kind = 'workshop' AND NOT qvm_new_apps.can_admin_workshop(p_owner_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this workshop is not yours to administer');
    END IF;
    IF p_owner_kind = 'vendor' AND NOT qvm_new_apps.can_admin_vendor(p_owner_id::integer) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this vendor is not yours to administer');
    END IF;
    IF p_owner_kind IS NULL AND NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
      RETURN jsonb_build_object('success', false, 'error', 'A customer needs a workshop or a vendor');
    END IF;

    INSERT INTO qvm_new_apps.end_customers
      (customer_kind, name, insurance_company_id, tax_number, contact_person, phone, email,
       requires_customer_approval, requires_workshop_approval, created_by, updated_by)
    VALUES (v_kind,
            CASE WHEN v_kind = 'insurance' THEN NULL ELSE NULLIF(btrim(COALESCE(p_name, '')), '') END,
            CASE WHEN v_kind = 'insurance' THEN p_insurance_company_id END,
            CASE WHEN v_kind = 'company' THEN NULLIF(btrim(COALESCE(p_tax_number, '')), '') END,
            NULLIF(btrim(COALESCE(p_contact_person, '')), ''),
            NULLIF(btrim(COALESCE(p_phone, '')), ''),
            NULLIF(lower(btrim(COALESCE(p_email, ''))), ''),
            COALESCE(p_requires_customer_approval, true), COALESCE(p_requires_workshop_approval, true),
            v_uid, v_uid)
    RETURNING end_customer_id INTO v_id;

    IF p_owner_kind IN ('workshop', 'vendor') THEN
      INSERT INTO qvm_new_apps.end_customer_owners (end_customer_id, workshop_id, vendor_id, created_by)
      VALUES (v_id,
              CASE WHEN p_owner_kind = 'workshop' THEN p_owner_id END,
              CASE WHEN p_owner_kind = 'vendor' THEN p_owner_id::integer END,
              v_uid);
    END IF;
  ELSE
    IF NOT qvm_new_apps.can_admin_end_customer(v_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Access denied: this customer is not yours to administer');
    END IF;
    -- The kind is not editable. Changing it would strand a tax number on an individual or leave an
    -- insurance customer pointing at a list row it no longer is.
    UPDATE qvm_new_apps.end_customers
       SET name = CASE WHEN customer_kind = 'insurance' THEN NULL
                       ELSE COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), name) END,
           insurance_company_id = CASE WHEN customer_kind = 'insurance'
                                       THEN COALESCE(p_insurance_company_id, insurance_company_id) END,
           tax_number = CASE WHEN customer_kind = 'company'
                             THEN NULLIF(btrim(COALESCE(p_tax_number, '')), '') END,
           contact_person = NULLIF(btrim(COALESCE(p_contact_person, '')), ''),
           phone = NULLIF(btrim(COALESCE(p_phone, '')), ''),
           email = NULLIF(lower(btrim(COALESCE(p_email, ''))), ''),
           requires_customer_approval = COALESCE(p_requires_customer_approval, requires_customer_approval),
           requires_workshop_approval = COALESCE(p_requires_workshop_approval, requires_workshop_approval),
           updated_by = v_uid, updated_at = now()
     WHERE end_customer_id = v_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'end_customer_id', v_id,
    'customer_code', (SELECT customer_code FROM qvm_new_apps.end_customers WHERE end_customer_id = v_id)));
END $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_end_customer(
  p_end_customer_id bigint DEFAULT NULL, p_customer_kind text DEFAULT NULL, p_name text DEFAULT NULL,
  p_insurance_company_id bigint DEFAULT NULL, p_tax_number text DEFAULT NULL,
  p_contact_person text DEFAULT NULL, p_phone text DEFAULT NULL, p_email text DEFAULT NULL,
  p_owner_kind text DEFAULT NULL, p_owner_id bigint DEFAULT NULL,
  p_requires_customer_approval boolean DEFAULT NULL, p_requires_workshop_approval boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_upsert_end_customer(p_end_customer_id, p_customer_kind, p_name,
             p_insurance_company_id, p_tax_number, p_contact_person, p_phone, p_email,
             p_owner_kind, p_owner_id, p_requires_customer_approval, p_requires_workshop_approval) $$;
REVOKE ALL ON FUNCTION public.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_upsert_end_customer(bigint, text, text, bigint, text, text, text, text, text, bigint, boolean, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_customer_tree()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH customer_json AS (
    SELECT c.end_customer_id,
           jsonb_build_object(
             'end_customer_id', c.end_customer_id,
             'display_name', c.name,
             'customer_kind', c.customer_kind,
             'customer_code', c.customer_code,
             'insurance_company_id', c.insurance_company_id,
             'tax_number', c.tax_number,
             'contact_person', c.contact_person,
             'phone', c.phone,
             'email', c.email,
             'is_active', c.is_active,
             'requires_customer_approval', c.requires_customer_approval,
             'requires_workshop_approval', c.requires_workshop_approval,
             'branch_count', c.branch_count,
             'user_count', c.user_count,
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'end_customer_branch_id', b.end_customer_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.end_customer_branches_descriptions bd
                                            WHERE bd.end_customer_branch_id = b.end_customer_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_end_customer_branches b
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.end_customer_id = c.end_customer_id), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.v_end_customers c
  ),
  -- Every workshop and vendor the caller can administer, as one list: on this screen they are the
  -- same kind of thing — somebody who has customers.
  owners AS (
    SELECT 'workshop'::text AS owner_kind, w.workshop_id::bigint AS owner_id, vw.name,
           w.workshop_code AS code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.workshop_companies x
             WHERE x.workshop_id = w.workshop_id) AS company_ids
      FROM qvm_new_apps.client_workshops w
      JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
     WHERE qvm_new_apps.can_admin_workshop(w.workshop_id)
    UNION ALL
    SELECT 'vendor', v.vendor_id::bigint, vv.name, v.vendor_code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.vendor_companies x
             WHERE x.vendor_id = v.vendor_id)
      FROM qvm_new_apps.vendors v
      JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
     WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    'insurance_companies', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', ic.id, 'name', ic.name)
                                                     ORDER BY ic.name)
                                       FROM qvm_new_apps.insurance_companies ic), '[]'::jsonb),
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                  FROM customer_json cj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_owners o
                                    WHERE o.end_customer_id = cj.end_customer_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'owners', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                     'owner_kind', o.owner_kind,
                     'owner_id', o.owner_id,
                     'display_name', o.name,
                     'code', o.code,
                     'customers', COALESCE((
                       SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                         FROM customer_json cj
                         JOIN qvm_new_apps.end_customer_owners eo
                           ON eo.end_customer_id = cj.end_customer_id
                          AND ((o.owner_kind = 'workshop' AND eo.workshop_id = o.owner_id)
                            OR (o.owner_kind = 'vendor'   AND eo.vendor_id = o.owner_id))), '[]'::jsonb))
                   ORDER BY o.owner_kind, o.name)
              FROM owners o
             WHERE o.company_ids @> to_jsonb(c.company_id)), '[]'::jsonb)
        ) AS co
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
      ) s), '[]'::jsonb)
  )) INTO v_res;

  RETURN v_res;
END $$;

-- ── The policy, as one row ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.quotation_approval_policy(p_quotation_id bigint)
 RETURNS TABLE(requires_customer boolean, requires_workshop boolean, has_end_customer boolean, end_customer_id bigint)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- An order with no end customer keeps the default: both sides.
  SELECT COALESCE(ec.requires_customer_approval, true),
         COALESCE(ec.requires_workshop_approval, true),
         ec.end_customer_id IS NOT NULL,
         ec.end_customer_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.end_customers ec ON ec.end_customer_id = q.end_customer_id
   WHERE q.quotation_id = p_quotation_id;
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.quotation_approval_policy(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_quotation_approval_policy(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT COALESCE((SELECT jsonb_build_object(
           'requires_customer_approval', p.requires_customer,
           'requires_workshop_approval', p.requires_workshop,
           'has_end_customer', p.has_end_customer,
           'end_customer_id', p.end_customer_id)
    FROM qvm_new_apps.quotation_approval_policy(p_quotation_id) p),
  jsonb_build_object('requires_customer_approval', true, 'requires_workshop_approval', true, 'has_end_customer', false, 'end_customer_id', NULL)) $$;
REVOKE ALL ON FUNCTION public.get_quotation_approval_policy(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_quotation_approval_policy(bigint) TO authenticated, service_role;

-- ── The lines cleared for purchase: approved by every side the policy requires ─────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.lines_cleared_for_purchase(p_quotation_id bigint)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- Empty when the policy requires nobody: then nothing is cleared BY APPROVAL — a priced line is
  -- bought as it is, through confirm_priced_lines.
  SELECT COALESCE(ARRAY(
    SELECT qi.quotation_item_id
      FROM qvm_new_apps.quotation_items qi
      CROSS JOIN qvm_new_apps.quotation_approval_policy(p_quotation_id) pol
     WHERE qi.quotation_id = p_quotation_id
       AND (pol.requires_workshop OR pol.requires_customer)
       AND (NOT pol.requires_workshop OR qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'workshop')))
       AND (NOT pol.requires_customer OR qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'client')))
     ORDER BY qi.quotation_item_id), ARRAY[]::bigint[]);
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.lines_cleared_for_purchase(bigint) TO authenticated, service_role;

-- ── Confirming lines: one writer, two callers ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_lines(p_quotation_id bigint, p_item_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_order bigint;
  v_n     integer := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_item_ids, ARRAY[]::bigint[])) id
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = id)
  ) THEN
    RETURN jsonb_build_object('confirmed', 0);
  END IF;

  SELECT co.confirmed_order_id INTO v_order
    FROM qvm_new_apps.confirmed_orders co WHERE co.quotation_id = p_quotation_id
   ORDER BY co.confirmed_order_id LIMIT 1;
  IF v_order IS NULL THEN
    INSERT INTO qvm_new_apps.confirmed_orders (quotation_id, created_at, updated_at)
    VALUES (p_quotation_id, clock_timestamp(), clock_timestamp())
    RETURNING confirmed_order_id INTO v_order;
  END IF;

  WITH ins AS (
    INSERT INTO qvm_new_apps.confirmed_items
      (confirmed_order_id, quotation_item_id, approved_qty, item_status, final_part_number, final_brand_class, created_at, updated_at)
    SELECT v_order, qi.quotation_item_id, GREATEST(COALESCE(qi.quantity, 1), 1), 19,
           COALESCE(ch.part_number, qi.alternative_part_number, qi.part_number),
           COALESCE(ch.brand_class, qi.brand_class),
           clock_timestamp(), clock_timestamp()
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.quotation_vendor_items sv ON sv.cost_id = qi.selected_cost_id
      LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = sv.chosen_alternative_id
     WHERE qi.quotation_id = p_quotation_id
       AND qi.quotation_item_id = ANY(p_item_ids)
       AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci WHERE ci.quotation_item_id = qi.quotation_item_id)
    RETURNING quotation_item_id
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_items qi
       SET item_status = 19, updated_at = now()
     WHERE qi.quotation_item_id IN (SELECT quotation_item_id FROM ins)
    RETURNING qi.quotation_item_id
  ),
  logged AS (
    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
    SELECT quotation_item_id, 19, auth.uid() FROM upd
    RETURNING quotation_item_id
  )
  SELECT count(*) INTO v_n FROM ins;

  RETURN jsonb_build_object('confirmed', v_n, 'confirmed_order_id', v_order);
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.confirm_lines(bigint, bigint[]) FROM PUBLIC;

-- Same name, same callers as before; now the lines cleared by the policy rather than by the workshop alone.
CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_approved_lines(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT qvm_new_apps.confirm_lines(p_quotation_id, qvm_new_apps.lines_cleared_for_purchase(p_quotation_id));
$function$;

-- With nobody to ask, a priced line is bought as it is. The pricing team confirms the lines it is
-- about to order; the purchase order is then built on them as on any confirmed line.
CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_priced_lines(p_quotation_id bigint, p_item_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  pol record;
  v_ids bigint[];
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can confirm lines for purchase';
  END IF;
  SELECT * INTO pol FROM qvm_new_apps.quotation_approval_policy(p_quotation_id);
  IF pol IS NULL OR NOT pol.has_end_customer OR pol.requires_workshop OR pol.requires_customer THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This customer requires an approval before purchase');
  END IF;
  -- Priced (17), with a wholesale price on the line.
  SELECT COALESCE(array_agg(qi.quotation_item_id), ARRAY[]::bigint[]) INTO v_ids
    FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_id = p_quotation_id
     AND qi.quotation_item_id = ANY(COALESCE(p_item_ids, ARRAY[]::bigint[]))
     AND qi.item_status = 17
     AND COALESCE(qi.price_before_vat, 0) > 0;
  RETURN jsonb_build_object('status', 'success') || qvm_new_apps.confirm_lines(p_quotation_id, v_ids);
END;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.confirm_priced_lines(bigint, bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.confirm_priced_lines(bigint, bigint[]) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.confirm_priced_lines(p_quotation_id bigint, p_item_ids bigint[])
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.confirm_priced_lines(p_quotation_id, p_item_ids) $$;
REVOKE ALL ON FUNCTION public.confirm_priced_lines(bigint, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_priced_lines(bigint, bigint[]) TO authenticated, service_role;

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
  END IF;
  -- Whichever side answered, the lines now cleared by everyone the customer's policy requires
  -- become confirmed items — the rows a purchase order is built on.
  IF p_decision = 'approved' THEN
    PERFORM qvm_new_apps.confirm_approved_lines(v_qid);
  END IF;

  RETURN jsonb_build_object('status', 'success', 'round_status', p_decision);
END;
$function$;

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
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id))) THEN
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

  -- The customer's yes may be the last signature the policy needs.
  PERFORM qvm_new_apps.confirm_approved_lines(p_quotation_id);

  RETURN jsonb_build_object('status', 'success', 'approval_round_id', v_round);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- The signatures the customer's policy asks for, before any purchase. A customer may require the
  -- workshop's confirmation of سعر الجملة, the customer's approval of سعر العميل, both (the default)
  -- or neither — with neither, a priced line may be bought as it is. An order with no end customer
  -- is judged the old way: both signatures, and only once it has been through the approval flow.
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_items) e
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
      CROSS JOIN LATERAL qvm_new_apps.quotation_approval_policy(qi.quotation_id) pol
     WHERE CASE
             WHEN pol.has_end_customer THEN
               (pol.requires_workshop OR pol.requires_customer)
               AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.lines_cleared_for_purchase(qi.quotation_id)))
             ELSE
               EXISTS (SELECT 1 FROM qvm_new_apps.quotation_approval_rounds r WHERE r.quotation_id = qi.quotation_id)
               AND NOT (qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'workshop'))
                        AND qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(qi.quotation_id, 'client')))
           END
  ) THEN
    RETURN jsonb_build_object('status', false,
      'message', 'Every line on a purchase order must first be approved by everyone this customer requires');
  END IF;


  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      -- When the buyer took one of the vendor's alternatives instead of the part asked for, the PO is
      -- for the alternative, at the alternative's price. Written here as final_purchase_price so every
      -- reader that already prefers it over the line's cost gets the right number. Left NULL for an
      -- ordinary line, which is exactly what happened before.
      final_purchase_price,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      (SELECT ch.unit_price
         FROM qvm_new_apps.quotation_vendor_items qvi
         JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = qvi.chosen_alternative_id
        WHERE qvi.cost_id = NULLIF(e->>'cost_id','')::INT),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id, cost_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
    RETURNING ci.confirmed_item_id, ci.quotation_item_id
  ),
  -- Save cost_id back to quotation_items so it can be restored when reopening pricing modal
  cost_id_update AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET cost_id = ii.cost_id, updated_at = NOW()
    FROM inserted_items ii
    JOIN status_update su ON su.confirmed_item_id = ii.confirmed_item_id
    WHERE qi.quotation_item_id = su.quotation_item_id
      AND ii.cost_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id
  JOIN status_update su ON su.confirmed_item_id = pi.confirmed_item_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 12 $$;
