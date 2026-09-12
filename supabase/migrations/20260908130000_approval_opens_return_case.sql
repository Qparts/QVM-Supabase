-- Approving a return opens the logistics case.
--
-- returned_issues was empty on every branch — dev and test alike, the latter with 338 purchase
-- orders of real data — because nothing could ever create the first row. The only INSERT in the
-- whole database is upsert_return_case; its only caller is the Complete Data modal; and that button
-- renders only on rows that came FROM returned_issues. No case, no button, no case.
--
-- The missing link was at the top: approval recorded the return thoroughly on the client and vendor
-- side but never opened the case that the whole returned_issues half of the dashboard exists to
-- track — who collects the goods, which courier, the pre-shipping photos, the supplier handling it.
-- Approval already knows everything the case needs to start.
--
-- Returns only. A cancelled item is not physically collected, so it gets no logistics case.
--
-- The upsert targets uq_return_case_item_order (confirmed_item_id, confirmed_order_id), the same
-- unique index upsert_return_case infers, so a second partial return on the same item updates that
-- item's case instead of opening a rival one. On conflict it deliberately touches only what
-- approval owns — the disposition and the reason — and leaves every logistics field alone, so
-- re-approving never wipes work the warehouse team has already done.

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(
  p_confirmed_item_id int,
  p_return_type int DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row qvm_new_apps.confirmed_items%ROWTYPE;
  v_approved_qty int;
  v_requested_qty int;
  v_remaining int;
  v_full boolean;
  v_new_status int;
  v_to_vendor boolean;
  v_pi_id bigint;
  v_pi_returned int;
  v_pi_ordered int;
  v_case_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_row.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;

  -- Cancellation request -> Canceled. No goods move, so no logistics case.
  IF v_row.item_status = 24 THEN
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 18, pending_request_note_id = NULL, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, 18, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', 18));
  END IF;

  IF v_row.item_status = 28 THEN
    IF p_return_type IS NOT NULL AND p_return_type NOT IN (133, 134, 135) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invalid return type');
    END IF;

    v_approved_qty  := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := LEAST(COALESCE(v_row.requested_return_qty, v_approved_qty), v_approved_qty);

    IF v_requested_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Return quantity must be greater than zero');
    END IF;

    v_full := v_requested_qty >= v_approved_qty;
    v_remaining  := CASE WHEN v_full THEN v_approved_qty ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 29 ELSE COALESCE(v_row.status_before_request, 23) END;

    -- Exchange (133) and Return to Supplier (135) both physically send the goods back, so both come
    -- off the purchase order. Return to Stock (134) does not: QVM keeps the part and still owes for it.
    v_to_vendor := p_return_type IN (133, 135);

    IF v_to_vendor THEN
      SELECT pi.purchase_item_id, COALESCE(pi.approved_qty, 0), COALESCE(pi.returned_qty, 0)
        INTO v_pi_id, v_pi_ordered, v_pi_returned
      FROM qvm_new_apps.purchase_items pi
      WHERE pi.confirmed_item_id = p_confirmed_item_id
        AND COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0) > 0
      ORDER BY pi.purchase_item_id DESC
      LIMIT 1;

      IF v_pi_id IS NOT NULL THEN
        UPDATE qvm_new_apps.purchase_items
        SET returned_qty = LEAST(v_pi_returned + v_requested_qty, v_pi_ordered),
            vendor_item_status = 166,  -- طلب ارجاع
            updated_by = v_uid,
            updated_at = now()
        WHERE purchase_item_id = v_pi_id;
      END IF;
    END IF;

    -- Open (or refresh) the logistics case. All three dispositions get one: even Return to Stock
    -- means the part has to physically travel from the client back to QVM.
    -- status is set to Return(29) rather than left NULL, so the case is visible and filterable with
    -- the same item_status vocabulary the dashboard's status filter already offers.
    INSERT INTO qvm_new_apps.returned_issues (
      confirmed_item_id, confirmed_order_id, status, return_type, return_reason,
      created_by, updated_by
    ) VALUES (
      p_confirmed_item_id, v_row.confirmed_order_id, 29, p_return_type, v_row.client_return_reason,
      v_uid, v_uid
    )
    ON CONFLICT (confirmed_item_id, confirmed_order_id) DO UPDATE SET
      status        = 29,
      return_type   = COALESCE(EXCLUDED.return_type, qvm_new_apps.returned_issues.return_type),
      return_reason = COALESCE(EXCLUDED.return_reason, qvm_new_apps.returned_issues.return_reason),
      updated_by    = EXCLUDED.updated_by,
      updated_at    = now()
    RETURNING returned_issue_id INTO v_case_id;

    INSERT INTO qvm_new_apps.confirmed_item_return_log
      (confirmed_item_id, returned_qty, remaining_qty, is_full_return, return_reason, return_type,
       purchase_item_id, note_id, approved_by, approved_at)
    VALUES (p_confirmed_item_id, v_requested_qty, v_remaining, v_full, v_row.client_return_reason,
            p_return_type, CASE WHEN v_to_vendor THEN v_pi_id END,
            v_row.pending_request_note_id, v_uid, now());

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty            = v_remaining,
        returned_qty            = COALESCE(returned_qty, 0) + v_requested_qty,
        item_status             = v_new_status,
        return_type             = COALESCE(p_return_type, return_type),
        client_return_reason    = CASE WHEN v_full THEN client_return_reason ELSE NULL END,
        requested_return_qty    = NULL,
        status_before_request   = NULL,
        pending_request_note_id = NULL,
        updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, v_new_status, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'full_return', v_full,
      'returned_qty', v_requested_qty,
      'remaining_qty', v_remaining,
      'return_type', p_return_type,
      'purchase_item_id', CASE WHEN v_to_vendor THEN v_pi_id END,
      'vendor_side_updated', v_to_vendor AND v_pi_id IS NOT NULL,
      'returned_issue_id', v_case_id
    ));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

-- Open cases for returns that were already approved, so the dashboard has the history rather than
-- starting from nothing. Covers both shapes: items sitting at Returned(29), and items whose
-- quantity was reduced by a partial return. Cancelled items are excluded, as above.
DO $backfill$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT ci.confirmed_item_id, ci.confirmed_order_id, ci.return_type,
           COALESCE(ci.client_return_reason,
                    (SELECT l.return_reason FROM qvm_new_apps.confirmed_item_return_log l
                      WHERE l.confirmed_item_id = ci.confirmed_item_id
                      ORDER BY l.return_log_id DESC LIMIT 1)) AS return_reason,
           (SELECT l.approved_by FROM qvm_new_apps.confirmed_item_return_log l
             WHERE l.confirmed_item_id = ci.confirmed_item_id
             ORDER BY l.return_log_id DESC LIMIT 1) AS approved_by
    FROM qvm_new_apps.confirmed_items ci
    WHERE (ci.item_status = 29 OR COALESCE(ci.returned_qty, 0) > 0)
      AND ci.confirmed_order_id IS NOT NULL
    ORDER BY ci.confirmed_item_id
  LOOP
    INSERT INTO qvm_new_apps.returned_issues (
      confirmed_item_id, confirmed_order_id, status, return_type, return_reason,
      created_by, updated_by
    ) VALUES (
      r.confirmed_item_id, r.confirmed_order_id, 29, r.return_type, r.return_reason,
      r.approved_by, r.approved_by
    )
    ON CONFLICT (confirmed_item_id, confirmed_order_id) DO NOTHING;

    n := n + 1;
  END LOOP;

  RAISE NOTICE 'opened return cases for % already-approved returns', n;
END
$backfill$;
