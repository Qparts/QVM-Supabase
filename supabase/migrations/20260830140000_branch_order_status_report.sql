-- Management Overview → "Management Reports" tab: third report block — per-client-branch stacked
-- bar of Confirmed / Pending(in-process) / Cancelled quotation counts.
--
-- Bucketing (verified live against qvm_new_apps.list_data, list_id = 3 "RFQ/Order status"):
--   Confirmed = the quotation has a qvm_new_apps.confirmed_orders row — the same order-level test
--     used throughout get_internal_actions/status_counts/get_internal_dashboard; no live code path
--     judges "confirmed" off item_status = 19 at the quotation grain.
--   Cancelled = NOT confirmed AND every one of the quotation's items is in a terminal-cancel status:
--     18 "Canceled" or 268 "Cancelled" (near-duplicate labels that both exist live; 268's id is
--     resolved by name at runtime, matching how the rest of the codebase always looks up "Cancelled"
--     / "Added by Vendor" by list_data name rather than hardcoding — see
--     20260717210659_qnew_vendor_added_items_approval_workflow.sql).
--   Pending = everything else not-confirmed/not-fully-cancelled. The user's own examples (Priced 17,
--     Sent To Vendor 237, Extract PN 236, Added by Vendor 267) all naturally fall in here alongside
--     New RFQ/Tendering/Ready For Quotation/Unavailable/etc. — this is a full 3-way partition of
--     every quotation touching the branch, not a fixed status allow-list.
-- Branch derivation is unchanged from get_branch_rfq_heatmap: quotation_items.customer_id matched
-- against client_branches.customer_id (quotations itself has no customer_id column).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_branch_order_status_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_cancelled_id integer;
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  SELECT list_data_id INTO v_cancelled_id
  FROM qvm_new_apps.list_data
  WHERE list_id = 3 AND list_data = 'Cancelled'
  LIMIT 1;

  WITH branch_quotations AS (
    SELECT DISTINCT cb.customer_id AS branch_id, cb.branch_name, qi.quotation_id
    FROM qvm_new_apps.client_branches cb
    JOIN qvm_new_apps.quotation_items qi ON qi.customer_id = cb.customer_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_branch_id IS NULL OR cb.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR cb.customer_id = ANY(v_branch_scope))
      AND (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
  ),
  classified AS (
    SELECT
      bq.branch_id,
      bq.branch_name,
      bq.quotation_id,
      EXISTS (
        SELECT 1 FROM qvm_new_apps.confirmed_orders co WHERE co.quotation_id = bq.quotation_id
      ) AS is_confirmed,
      NOT EXISTS (
        SELECT 1 FROM qvm_new_apps.quotation_items qi2
        WHERE qi2.quotation_id = bq.quotation_id
          AND qi2.item_status NOT IN (18, COALESCE(v_cancelled_id, -1))
      ) AS is_all_cancelled
    FROM branch_quotations bq
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.total_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      branch_id,
      branch_name,
      count(*) FILTER (WHERE is_confirmed) AS confirmed_count,
      count(*) FILTER (WHERE NOT is_confirmed AND is_all_cancelled) AS cancelled_count,
      count(*) FILTER (WHERE NOT is_confirmed AND NOT is_all_cancelled) AS pending_count,
      count(*) AS total_count
    FROM classified
    GROUP BY branch_id, branch_name
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_branch_order_status_report(integer, timestamptz, timestamptz) TO authenticated;
