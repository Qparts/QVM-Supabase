-- The workshop's approval is the confirmation.
--
-- A purchase order is built on confirmed_orders and confirmed_items — the rows the RFQ dashboard's
-- "confirm to cart" step creates. The approval flow never created them, so an order the workshop
-- and the customer had both signed off still had no Create Purchase Order button: nothing for it to
-- stand on. COMW4 sat exactly there.
--
-- Now a workshop round that comes back approved writes those rows for the lines it approved, in the
-- same shape confirm_cart_items writes them (approved quantity, final part number, final class,
-- item status 19, a status log), so everything downstream — the PO, receiving, invoicing — sees a
-- confirmed line and cannot tell which door it came in by. Lines already confirmed are left alone.

CREATE OR REPLACE FUNCTION qvm_new_apps.confirm_approved_lines(p_quotation_id bigint)
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
    SELECT 1 FROM unnest(qvm_new_apps.approved_item_ids(p_quotation_id, 'workshop')) id
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
           -- The part actually agreed: the chosen alternative's number when the buyer took one.
           COALESCE(ch.part_number, qi.alternative_part_number, qi.part_number),
           COALESCE(ch.brand_class, qi.brand_class),
           clock_timestamp(), clock_timestamp()
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.quotation_vendor_items sv ON sv.cost_id = qi.selected_cost_id
      LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives ch ON ch.alternative_id = sv.chosen_alternative_id
     WHERE qi.quotation_id = p_quotation_id
       AND qi.quotation_item_id = ANY(qvm_new_apps.approved_item_ids(p_quotation_id, 'workshop'))
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
REVOKE ALL ON FUNCTION qvm_new_apps.confirm_approved_lines(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.confirm_approved_lines(bigint) TO authenticated, service_role;

-- ── The workshop's approval calls it ──────────────────────────────────────────────────────────
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
    PERFORM qvm_new_apps.confirm_approved_lines(v_qid);
  END IF;

  RETURN jsonb_build_object('status', 'success', 'round_status', p_decision);
END;
$function$;

-- ── Orders approved before this existed ───────────────────────────────────────────────────────
DO $backfill$
DECLARE q record;
BEGIN
  FOR q IN SELECT DISTINCT r.quotation_id FROM qvm_new_apps.quotation_approval_rounds r
            WHERE r.audience = 'workshop' AND r.status = 'approved'
  LOOP
    PERFORM qvm_new_apps.confirm_approved_lines(q.quotation_id);
  END LOOP;
END
$backfill$;
