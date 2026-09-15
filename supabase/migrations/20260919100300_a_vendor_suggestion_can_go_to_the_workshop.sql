-- A part the vendor suggested can be put to the workshop instead of decided for them.
--
-- A vendor adding an item to an order already lands as "Added by Vendor" and waits for the pricing
-- team to accept or reject it. That is the right default for a part the team can judge on its own —
-- a missing clip, an obvious consumable. It is the wrong default for a part that changes what the
-- customer is buying, and the team has no standing to decide that. So the pricing team now has a
-- third answer: ask the workshop.
--
-- One new status carries it. "Pending Workshop Approval" is not "Added by Vendor" — the pricing
-- team has already looked and has deliberately passed it on, and the two must not read alike in a
-- queue. Nothing else in the order's arithmetic counts either status: a suggested part is not part
-- of the order until somebody says it is.

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 3, 'Pending Workshop Approval'
WHERE NOT EXISTS (
  SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Pending Workshop Approval');

-- Clear the way first.
--
-- CREATE OR REPLACE cannot change a function's return type or its argument names, and this project
-- is full of functions that exist only in the live database and in no migration — get_brand_classes
-- and get_parts_pricing_history are both like that. If one of the names below is already taken by
-- such a function with a different shape, the CREATE fails and takes the whole deploy with it,
-- which is what happened the first time this file went out.
--
-- Dropping every overload by name rather than by signature, because a signature-specific DROP
-- misses exactly the case that causes the failure. None of these names is referenced anywhere in
-- this repository, so nothing here can be pulling the rug from under a caller.
DO $drop$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname IN ('public', 'qvm_new_apps')
              AND p.proname IN ('workshop_users_for_quotation', 'send_added_item_to_workshop',
                                 'workshop_decide_added_item', 'list_suggested_items')
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END
$drop$;

-- Who counts as "the workshop" for an order: the people at the company that raised it, narrowed to
-- the branch the order's lines were raised for when the reader is pinned to one branch. Client-side
-- users only (183) — an internal user reading their own company's orders is not the customer.
--
-- A quotation has no branch of its own. It carries company_id and nothing else; the branch lives on
-- each LINE, as quotation_items.customer_id, which is a client_branches row and is exactly what
-- user_data.user_branch is matched against elsewhere. Reading a q.branch_id that does not exist is
-- what stopped this file's first three deploys.
--
-- SETOF uuid rather than a named output column, which would share its name with the column the body
-- selects; the callers only ever want the ids.
CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_users_for_quotation(p_quotation_id bigint)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT DISTINCT ud.user_id
    FROM qvm_new_apps.quotations q
    JOIN qvm_new_apps.user_data ud ON ud.user_company = q.company_id
   WHERE q.quotation_id = p_quotation_id
     AND ud.user_type = 183
     AND ud.deleted_at IS NULL
     -- A user with no branch of their own speaks for the whole company; one pinned to a branch only
     -- hears about orders that branch actually raised a line on.
     AND (ud.user_branch IS NULL
          OR EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi
                      WHERE qi.quotation_id = q.quotation_id
                        AND qi.customer_id = ud.user_branch));
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.workshop_users_for_quotation(bigint) FROM PUBLIC;

-- ── The pricing team hands it over ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.send_added_item_to_workshop(p_quotation_item_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_added    integer;
  v_pending  integer;
  v_cur      integer;
  v_qid      bigint;
  v_part     text;
  v_order    text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can send a suggested part to the workshop';
  END IF;

  SELECT list_data_id INTO v_added
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;
  SELECT list_data_id INTO v_pending
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Pending Workshop Approval' LIMIT 1;

  SELECT qi.item_status, qi.quotation_id, COALESCE(qi.part_number, qi.part_description)
    INTO v_cur, v_qid, v_part
    FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id;

  IF v_cur IS NULL THEN RAISE EXCEPTION 'Item not found'; END IF;
  IF v_cur <> v_added THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This part is not waiting on a decision');
  END IF;

  UPDATE qvm_new_apps.quotation_items
     SET item_status = v_pending, updated_at = now()
   WHERE quotation_item_id = p_quotation_item_id;

  SELECT order_number INTO v_order FROM qvm_new_apps.quotations WHERE quotation_id = v_qid;

  WITH sent AS (
    INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
    SELECT 'قطعة مقترحة بانتظار موافقتك',
           'أضاف المورّد القطعة ' || COALESCE(v_part, '') || ' إلى الطلب ' || COALESCE(v_order, ''),
           jsonb_build_object('quotation_id', v_qid, 'quotation_item_id', p_quotation_item_id),
           'user', w, auth.uid()
      FROM qvm_new_apps.workshop_users_for_quotation(v_qid) AS w
    RETURNING id, target_user_id
  )
  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  SELECT sent.id, sent.target_user_id FROM sent WHERE sent.target_user_id IS NOT NULL;

  RETURN jsonb_build_object('status', 'success', 'item_status', v_pending);
END;
$function$;

-- ── The workshop answers ──────────────────────────────────────────────────────────────────────
--
-- Approving lands the part on exactly the status the pricing team's own "accept" produces, so from
-- here on there is one kind of accepted part and nothing downstream has to know which route it took.
CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_decide_added_item(
  p_quotation_item_id bigint, p_approve boolean, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_pending integer;
  v_sent    integer;
  v_cancel  integer;
  v_cur     integer;
  v_qid     bigint;
  v_new     integer;
BEGIN
  SELECT list_data_id INTO v_pending
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Pending Workshop Approval' LIMIT 1;
  SELECT list_data_id INTO v_sent
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor' LIMIT 1;
  SELECT list_data_id INTO v_cancel
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Cancelled' LIMIT 1;

  SELECT qi.item_status, qi.quotation_id INTO v_cur, v_qid
    FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id;

  IF v_cur IS NULL THEN RAISE EXCEPTION 'Item not found'; END IF;
  IF v_cur <> v_pending THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This part is not waiting on the workshop');
  END IF;

  -- The workshop the part was sent to, or the Qparts team acting for them when they ask by phone.
  IF NOT (auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(v_qid))
          OR qvm_new_apps.is_qparts_team()) THEN
    RAISE EXCEPTION 'This part was not sent to you';
  END IF;

  v_new := CASE WHEN p_approve THEN v_sent ELSE v_cancel END;

  UPDATE qvm_new_apps.quotation_items
     SET item_status = v_new, updated_at = now()
   WHERE quotation_item_id = p_quotation_item_id;

  IF NOT p_approve AND COALESCE(btrim(p_reason), '') <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items', p_type_id := p_quotation_item_id,
        p_note_description := 'Workshop rejected: ' || p_reason, p_note_id := NULL,
        p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'item_status', v_new);
END;
$function$;

-- Parts on an order that are still somebody's suggestion rather than part of the order. The pricing
-- page and the workshop's own view both need to tell them apart from the real lines, and from each
-- other, without hardcoding a list_data id in the frontend.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_suggested_items(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'quotation_item_id', qi.quotation_item_id,
             'part_number',       qi.part_number,
             'part_description',  qi.part_description,
             'quantity',          qi.quantity,
             'item_status',       qi.item_status,
             'item_status_name',  ld.list_data,
             'stage', CASE WHEN ld.list_data = 'Added by Vendor' THEN 'qparts'
                           ELSE 'workshop' END,
             'suggested_by_vendor', (SELECT v.vendor_name
                                       FROM qvm_new_apps.quotation_vendor_items qvi
                                       LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
                                      WHERE qvi.quotation_item_id = qi.quotation_item_id
                                      ORDER BY qvi.cost_id LIMIT 1),
             'cost', (SELECT qvi2.cost FROM qvm_new_apps.quotation_vendor_items qvi2
                       WHERE qvi2.quotation_item_id = qi.quotation_item_id
                       ORDER BY qvi2.cost_id LIMIT 1),
             'created_at', qi.created_at) ORDER BY qi.quotation_item_id)
      FROM qvm_new_apps.quotation_items qi
      JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
     WHERE qi.quotation_id = p_quotation_id
       AND ld.list_id = 3
       AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval')), '[]'::jsonb);
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_added_item_to_workshop(p_quotation_item_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.send_added_item_to_workshop(p_quotation_item_id); $$;

CREATE OR REPLACE FUNCTION public.workshop_decide_added_item(p_quotation_item_id bigint, p_approve boolean, p_reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.workshop_decide_added_item(p_quotation_item_id, p_approve, p_reason); $$;

CREATE OR REPLACE FUNCTION public.list_suggested_items(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_suggested_items(p_quotation_id); $$;

REVOKE ALL ON FUNCTION public.send_added_item_to_workshop(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.workshop_decide_added_item(bigint, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_suggested_items(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.send_added_item_to_workshop(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.workshop_decide_added_item(bigint, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_suggested_items(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.send_added_item_to_workshop(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.workshop_decide_added_item(bigint, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_suggested_items(bigint) TO authenticated, service_role;
