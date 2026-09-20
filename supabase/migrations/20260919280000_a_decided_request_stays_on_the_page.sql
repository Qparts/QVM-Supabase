-- A decided request stays on the returns & exchanges page.
--
-- An approved return leaves a case behind; an approved or rejected cancellation, and a rejected
-- return, left nothing — the item simply changed status and the request vanished from the page.
-- Decisions are now records of their own, written by the approve and reject RPCs, shown on the
-- page as decided rows (read-only, with who decided and when), and backfilled from the status
-- history as far as it can tell: a request followed by Canceled or Returned is an approval; any
-- other outcome is recorded as resolved, since a partial approval and a rejection leave the same trace.
CREATE TABLE IF NOT EXISTS qvm_new_apps.item_request_decisions (
  decision_id       bigserial PRIMARY KEY,
  confirmed_item_id integer NOT NULL,
  request_kind      text NOT NULL CHECK (request_kind IN ('cancellation', 'return')),
  decision          text NOT NULL CHECK (decision IN ('approved', 'rejected', 'resolved')),
  requested_qty     integer,
  full_request      boolean,
  return_type       integer,
  reason_id         integer,
  note              text,
  decided_by        uuid,
  decided_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_item_request_decisions_item ON qvm_new_apps.item_request_decisions (confirmed_item_id, decided_at);
GRANT SELECT ON qvm_new_apps.item_request_decisions TO authenticated, service_role;
GRANT INSERT ON qvm_new_apps.item_request_decisions TO service_role;

-- History, as far as it can tell.
INSERT INTO qvm_new_apps.item_request_decisions (confirmed_item_id, request_kind, decision, decided_by, decided_at)
SELECT r.confirmed_item_id,
       CASE r.item_status WHEN 24 THEN 'cancellation' ELSE 'return' END,
       CASE WHEN (r.item_status = 24 AND n.item_status = 18) OR (r.item_status = 28 AND n.item_status = 29) THEN 'approved' ELSE 'resolved' END,
       n.status_changed_by, n.created_at
  FROM qvm_new_apps.status_logs r
  JOIN LATERAL (
    SELECT s.item_status, s.status_changed_by, s.created_at
      FROM qvm_new_apps.status_logs s
     WHERE s.confirmed_item_id = r.confirmed_item_id AND s.created_at > r.created_at
     ORDER BY s.created_at LIMIT 1) n ON true
 WHERE r.confirmed_item_id IS NOT NULL AND r.item_status IN (24, 28)
   AND n.item_status NOT IN (24, 28)
   AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.item_request_decisions d WHERE d.confirmed_item_id = r.confirmed_item_id AND d.decided_at = n.created_at);

CREATE OR REPLACE FUNCTION qvm_new_apps.approve_item_status_request(p_confirmed_item_id integer, p_return_type integer DEFAULT NULL::integer)
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
  v_received int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT * INTO v_row FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_row.confirmed_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;

  ---------------------------------------------------------------------------- cancellation
  IF v_row.item_status = 24 THEN
    v_approved_qty  := COALESCE(v_row.approved_qty, 0);
    v_requested_qty := LEAST(COALESCE(NULLIF(v_row.requested_cancel_qty, 0), v_approved_qty), v_approved_qty);
    v_full := v_requested_qty >= v_approved_qty OR v_approved_qty = 0;
    v_remaining := CASE WHEN v_full THEN 0 ELSE v_approved_qty - v_requested_qty END;
    v_new_status := CASE WHEN v_full THEN 18 ELSE COALESCE(v_row.status_before_request, 19) END;

    -- Take it off the purchase order too — the line the request was raised from, falling back to
    -- the newest for a request made before that was recorded. Never below what already arrived.
    SELECT pi.purchase_item_id, COALESCE(pi.approved_qty,0),
           COALESCE((SELECT sum(ri.received_qty) FROM qvm_new_apps.purchase_receipt_round_items ri
                      WHERE ri.purchase_item_id = pi.purchase_item_id), 0)
      INTO v_pi_id, v_pi_ordered, v_received
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.confirmed_item_id = p_confirmed_item_id
      AND (v_row.pending_request_purchase_item_id IS NULL
           OR pi.purchase_item_id = v_row.pending_request_purchase_item_id)
    ORDER BY pi.purchase_item_id DESC
    LIMIT 1;

    IF v_pi_id IS NOT NULL THEN
      UPDATE qvm_new_apps.purchase_items
      SET approved_qty = GREATEST(v_pi_ordered - v_requested_qty, v_received),
          vendor_item_status = CASE WHEN GREATEST(v_pi_ordered - v_requested_qty, v_received) <= 0
                                    THEN 160 ELSE vendor_item_status END,   -- الغاء
          updated_by = v_uid, updated_at = now()
      WHERE purchase_item_id = v_pi_id;
    END IF;

    UPDATE qvm_new_apps.confirmed_items
    SET approved_qty            = CASE WHEN v_full THEN approved_qty ELSE v_remaining END,
        item_status             = v_new_status,
        requested_cancel_qty    = NULL,
        pending_request_purchase_item_id = NULL,
        status_before_request   = NULL,
        pending_request_note_id = NULL,
        updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (p_confirmed_item_id, v_new_status, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

    INSERT INTO qvm_new_apps.item_request_decisions
      (confirmed_item_id, request_kind, decision, requested_qty, full_request, reason_id, decided_by)
    VALUES (p_confirmed_item_id, 'cancellation', 'approved', v_requested_qty, v_full, v_row.cancellation_reason, v_uid);
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'cancelled_qty', v_requested_qty,
      'remaining_qty', CASE WHEN v_full THEN 0 ELSE v_remaining END,
      'full_cancellation', v_full));
  END IF;

  ---------------------------------------------------------------------------- return
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

    -- Exchange (133) and Return to Supplier (135) both send the goods back, so both come off the
    -- purchase order. Return to Stock (134) does not: QVM keeps the part and still owes for it.
    v_to_vendor := p_return_type IN (133, 135);

    IF v_to_vendor THEN
      -- The line the request was raised from. An item split across two purchase orders has two
      -- candidates, and guessing at the newest sends the wrong vendor a return; falling back to it
      -- only for requests made before this was recorded.
      SELECT pi.purchase_item_id, COALESCE(pi.approved_qty, 0), COALESCE(pi.returned_qty, 0)
        INTO v_pi_id, v_pi_ordered, v_pi_returned
      FROM qvm_new_apps.purchase_items pi
      WHERE pi.confirmed_item_id = p_confirmed_item_id
        AND (v_row.pending_request_purchase_item_id IS NOT NULL
             OR COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0) > 0)
        AND (v_row.pending_request_purchase_item_id IS NULL
             OR pi.purchase_item_id = v_row.pending_request_purchase_item_id)
      ORDER BY pi.purchase_item_id DESC
      LIMIT 1;

      IF v_pi_id IS NOT NULL THEN
        UPDATE qvm_new_apps.purchase_items
        SET returned_qty = LEAST(v_pi_returned + v_requested_qty, v_pi_ordered),
            vendor_item_status = 166,  -- طلب ارجاع
            updated_by = v_uid, updated_at = now()
        WHERE purchase_item_id = v_pi_id;
      END IF;
    END IF;

    INSERT INTO qvm_new_apps.returned_issues (
      confirmed_item_id, confirmed_order_id, status, return_type, return_reason, created_by, updated_by
    ) VALUES (
      p_confirmed_item_id, v_row.confirmed_order_id, 29, p_return_type, v_row.client_return_reason, v_uid, v_uid
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
        pending_request_purchase_item_id = NULL,
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

    INSERT INTO qvm_new_apps.item_request_decisions
      (confirmed_item_id, request_kind, decision, requested_qty, full_request, return_type, reason_id, decided_by)
    VALUES (p_confirmed_item_id, 'return', 'approved', v_requested_qty, v_full, p_return_type, v_row.client_return_reason, v_uid);
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'new_status', v_new_status,
      'full_return', v_full,
      'returned_qty', v_requested_qty,
      'remaining_qty', v_remaining,
      'return_type', p_return_type,
      'purchase_item_id', CASE WHEN v_to_vendor THEN v_pi_id END,
      'vendor_side_updated', v_to_vendor AND v_pi_id IS NOT NULL,
      'returned_issue_id', v_case_id));
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.reject_item_status_request(p_confirmed_item_id int, p_resolution_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_status int;
  v_prev int;
  v_req_qty int;
  v_reason int;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Internal users only');
  END IF;

  SELECT item_status, status_before_request,
         CASE WHEN item_status = 24 THEN requested_cancel_qty ELSE requested_return_qty END,
         CASE WHEN item_status = 24 THEN cancellation_reason ELSE client_return_reason END
    INTO v_status, v_prev, v_req_qty, v_reason
  FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;
  IF v_status IS NULL OR v_status NOT IN (24, 28) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item has no pending request');
  END IF;

  UPDATE qvm_new_apps.confirmed_items
  SET item_status = COALESCE(v_prev, 19), status_before_request = NULL, pending_request_note_id = NULL,
      requested_return_qty = NULL, requested_cancel_qty = NULL,
      pending_request_purchase_item_id = NULL,
      updated_by = v_uid, updated_at = now()
  WHERE confirmed_item_id = p_confirmed_item_id;

  INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
  VALUES (p_confirmed_item_id, COALESCE(v_prev, 19), v_uid);

  PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(p_confirmed_item_id);

  -- The decision stays on record: the dashboard shows rejected requests, not only open ones.
  INSERT INTO qvm_new_apps.item_request_decisions
    (confirmed_item_id, request_kind, decision, requested_qty, full_request, reason_id, note, decided_by)
  VALUES (p_confirmed_item_id, CASE WHEN v_status = 24 THEN 'cancellation' ELSE 'return' END, 'rejected',
          v_req_qty, NULL, v_reason, NULLIF(trim(COALESCE(p_resolution_note, '')), ''), v_uid);

  IF p_resolution_note IS NOT NULL AND trim(p_resolution_note) <> '' THEN
    PERFORM qvm_new_apps.add_note(p_note_type := 'confirmed_items', p_type_id := p_confirmed_item_id,
      p_is_internal := false, p_note_description := 'Request rejected: ' || p_resolution_note,
      p_note_attachment := NULL, p_kind := 'comment');
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('new_status', COALESCE(v_prev, 19)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_return_exchange_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_return_type_ids integer[] DEFAULT NULL::integer[], p_status_ids integer[] DEFAULT NULL::integer[], p_branch_ids integer[] DEFAULT NULL::integer[], p_sort_by text DEFAULT 'order_date'::text, p_sort_dir text DEFAULT 'desc'::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  rows jsonb;
  total int;
BEGIN
  WITH user_ctx AS (
    SELECT (ud.user_type = 185) AS is_internal,
           -- NULL for an unrestricted account; the branch list for a scoped one.
           qvm_new_apps.get_internal_branch_scope(ud.user_id) AS branch_scope
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  cases AS (
    SELECT
      'case:' || ri.returned_issue_id            AS row_key,
      'case'::text                               AS record_type,
      ri.returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at                               AS order_date,
      COALESCE(qi.customer_id, qbr.customer_id)  AS customer_id,
      cb.branch_name,
      ld_client.list_data                        AS client_name,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data                              AS final_brand_class,
      ci.approved_qty,
      NULL::int                                  AS requested_qty,
      ri.status                                  AS status_id,
      ld_status.list_data                        AS status,
      ri.return_type                             AS return_type_id,
      ld_rt.list_data                            AS return_type,
      COALESCE(ri.main_supplier, qvi.vendor_id)  AS main_supplier_id,
      coalesce(ld_sup.list_data, ldv.list_data)  AS main_supplier,
      udr.user_name                              AS delivery_representative,
      ld_src.list_data                           AS part_number_extraction_source,
      ld_reason.list_data                        AS return_reason,
      NULL::text                                 AS note_text,
      NULL::text                                 AS requested_by_name,
      NULL::timestamptz                          AS requested_at,
      ri.pre_shipping_photo_done,
      ri.post_photo_review_done,
      coalesce(att.urls, '[]'::jsonb)            AS attachments
    FROM qvm_new_apps.returned_issues ri
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ri.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN LATERAL (
      SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
      WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
      ORDER BY qi0.quotation_item_id ASC LIMIT 1
    ) qbr ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = COALESCE(qi.customer_id, qbr.customer_id)
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ri.status
    LEFT JOIN qvm_new_apps.list_data ld_rt ON ld_rt.list_data_id = ri.return_type
    LEFT JOIN qvm_new_apps.list_data ld_sup ON ld_sup.list_data_id = ri.main_supplier
    LEFT JOIN qvm_new_apps.user_data udr ON udr.user_id = ri.delivery_representative
    LEFT JOIN qvm_new_apps.list_data ld_src ON ld_src.list_data_id = ri.extraction_source
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id = ri.return_reason
    LEFT JOIN LATERAL (
      SELECT coalesce(jsonb_agg(jsonb_build_object('url', ria.file_url, 'path', NULL)
                                ORDER BY ria.uploaded_at DESC), '[]'::jsonb) AS urls
      FROM qvm_new_apps.returned_issue_attachments ria
      WHERE ria.returned_issue_id = ri.returned_issue_id
    ) att ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL
                              OR COALESCE(qi.customer_id, qbr.customer_id) = ANY(uc.branch_scope)))
  ),
  requests AS (
    SELECT
      'req:' || ci.confirmed_item_id             AS row_key,
      CASE ci.item_status WHEN 24 THEN 'cancellation_request' ELSE 'return_request' END AS record_type,
      NULL::bigint                               AS returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at                               AS order_date,
      COALESCE(qi.customer_id, qbr.customer_id)  AS customer_id,
      cb.branch_name,
      ld_client.list_data                        AS client_name,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data                              AS final_brand_class,
      ci.approved_qty,
      ci.requested_return_qty                    AS requested_qty,
      ci.item_status                             AS status_id,
      ld_status.list_data                        AS status,
      NULL::int                                  AS return_type_id,
      NULL::text                                 AS return_type,
      qvi.vendor_id                              AS main_supplier_id,
      ldv.list_data                              AS main_supplier,
      NULL::text                                 AS delivery_representative,
      NULL::text                                 AS part_number_extraction_source,
      ld_reason.list_data                        AS return_reason,
      nt.note_text,
      (SELECT ud2.user_name FROM qvm_new_apps.user_data ud2 WHERE ud2.user_id = (
         SELECT sl.status_changed_by FROM qvm_new_apps.status_logs sl
         WHERE sl.confirmed_item_id = ci.confirmed_item_id AND sl.item_status = ci.item_status
         ORDER BY sl.created_at DESC LIMIT 1
       ))                                        AS requested_by_name,
      ci.updated_at                              AS requested_at,
      NULL::boolean                              AS pre_shipping_photo_done,
      NULL::boolean                              AS post_photo_review_done,
      coalesce(natt.files, '[]'::jsonb)          AS attachments
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN LATERAL (
      SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
      WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
      ORDER BY qi0.quotation_item_id ASC LIMIT 1
    ) qbr ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = COALESCE(qi.customer_id, qbr.customer_id)
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id =
      (CASE WHEN ci.item_status = 24 THEN ci.cancellation_reason ELSE ci.client_return_reason END)
    -- The request's own note, not merely the newest note on the item.
    LEFT JOIN LATERAL (
      SELECT n.note_id, n.note_description AS note_text
      FROM qvm_new_apps.notes n
      WHERE n.note_type = 'confirmed_items'
        AND n.type_id = ci.confirmed_item_id
        AND (ci.pending_request_note_id IS NULL OR n.note_id = ci.pending_request_note_id)
      ORDER BY n.created_at DESC
      LIMIT 1
    ) nt ON true
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object('url', NULL, 'path', f.file_path)) AS files
      FROM qvm_new_apps.files f
      WHERE f.module_type = 'notes' AND f.module_id = nt.note_id
    ) natt ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL
                              OR COALESCE(qi.customer_id, qbr.customer_id) = ANY(uc.branch_scope)))
      AND ci.item_status IN (24, 28)
  ),
  decisions AS (
    SELECT
      'dec:' || d.decision_id                    AS row_key,
      CASE d.request_kind WHEN 'cancellation' THEN 'cancellation_decided' ELSE 'return_decided' END AS record_type,
      NULL::bigint                               AS returned_issue_id,
      ci.confirmed_item_id,
      co.confirmed_order_id,
      q.order_number,
      q.created_at                               AS order_date,
      COALESCE(qi.customer_id, qbr.customer_id)  AS customer_id,
      cb.branch_name,
      ld_client.list_data                        AS client_name,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data                              AS final_brand_class,
      ci.approved_qty,
      d.requested_qty                            AS requested_qty,
      ci.item_status                             AS status_id,
      (CASE d.request_kind WHEN 'cancellation' THEN 'Cancellation' ELSE 'Return' END || ' ' || d.decision) AS status,
      d.return_type                              AS return_type_id,
      ld_drt.list_data                           AS return_type,
      qvi.vendor_id                              AS main_supplier_id,
      ldv.list_data                              AS main_supplier,
      NULL::text                                 AS delivery_representative,
      NULL::text                                 AS part_number_extraction_source,
      ld_reason.list_data                        AS return_reason,
      COALESCE(d.note, nt.note_text)             AS note_text,
      (SELECT ud2.user_name FROM qvm_new_apps.user_data ud2 WHERE ud2.user_id = d.decided_by) AS requested_by_name,
      d.decided_at                               AS requested_at,
      NULL::boolean                              AS pre_shipping_photo_done,
      NULL::boolean                              AS post_photo_review_done,
      coalesce(natt.files, '[]'::jsonb)          AS attachments
    FROM qvm_new_apps.item_request_decisions d
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = d.confirmed_item_id
    LEFT JOIN qvm_new_apps.list_data ld_drt ON ld_drt.list_data_id = d.return_type
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN LATERAL (
      SELECT qi0.customer_id FROM qvm_new_apps.quotation_items qi0
      WHERE qi0.quotation_id = q.quotation_id AND qi0.customer_id IS NOT NULL
      ORDER BY qi0.quotation_item_id ASC LIMIT 1
    ) qbr ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = COALESCE(qi.customer_id, qbr.customer_id)
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.list_data ldv ON ldv.list_data_id = qvi.vendor_id
    LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    LEFT JOIN qvm_new_apps.list_data ld_reason ON ld_reason.list_data_id =
      d.reason_id
    -- The request's own note, not merely the newest note on the item.
    LEFT JOIN LATERAL (
      SELECT n.note_id, n.note_description AS note_text
      FROM qvm_new_apps.notes n
      WHERE n.note_type = 'confirmed_items'
        AND n.type_id = ci.confirmed_item_id
        AND (ci.pending_request_note_id IS NULL OR n.note_id = ci.pending_request_note_id)
      ORDER BY n.created_at DESC
      LIMIT 1
    ) nt ON true
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object('url', NULL, 'path', f.file_path)) AS files
      FROM qvm_new_apps.files f
      WHERE f.module_type = 'notes' AND f.module_id = nt.note_id
    ) natt ON true
    JOIN user_ctx uc ON true
    WHERE (uc.is_internal AND (uc.branch_scope IS NULL
                              OR COALESCE(qi.customer_id, qbr.customer_id) = ANY(uc.branch_scope)))
  ),
  unioned AS (
    SELECT * FROM cases
    UNION ALL
    SELECT * FROM requests
    UNION ALL
    SELECT * FROM decisions
  ),
  filtered AS (
    SELECT * FROM unioned i
    WHERE (s = '' OR
           position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.branch_name, ''))) > 0 OR
           position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (p_return_type_ids IS NULL OR i.return_type_id = ANY(p_return_type_ids))
      AND (p_status_ids IS NULL OR i.status_id = ANY(p_status_ids))
      AND (p_branch_ids IS NULL OR i.customer_id = ANY(p_branch_ids))
  ),
  -- Numbered over the final ordering, so the page and the total come from one pass.
  ordered AS (
    SELECT f.*, row_number() OVER (
      ORDER BY
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) = 'asc'  THEN f.order_date END ASC  NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'order_date' AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN f.order_date END DESC NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'status'     AND lower(coalesce(p_sort_dir,'')) = 'asc'  THEN f.status     END ASC  NULLS LAST,
        CASE WHEN lower(coalesce(p_sort_by,'')) = 'status'     AND lower(coalesce(p_sort_dir,'')) <> 'asc' THEN f.status     END DESC NULLS LAST,
        f.order_number DESC,
        f.confirmed_item_id ASC
    ) AS rn
    FROM filtered f
  )
  SELECT
    count(*)::int,
    coalesce(
      jsonb_agg(to_jsonb(o) - 'rn' ORDER BY o.rn)
        FILTER (WHERE o.rn > p_offset AND o.rn <= p_offset + p_limit),
      '[]'::jsonb)
  INTO total, rows
  FROM ordered o;

  RETURN jsonb_build_object(
    'status','success',
    'message','OK',
    'total', total,
    'rows', rows
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 32 $$;
