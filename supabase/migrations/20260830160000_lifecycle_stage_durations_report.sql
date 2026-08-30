-- Management Overview → "Management Reports" tab: sixth report block — % of total tracked
-- lifecycle time spent in each item-status transition (e.g. "Ready For Quotation → Sent To
-- Vendor"), derived from qvm_new_apps.status_logs.
--
-- Known, verified-live limitations (flagging deliberately rather than silently glossing over them):
--   1. status_logs only ever has quotation_item_id populated on this DB (0 confirmed_item_id rows
--      exist) — logging of the post-Confirmed lifecycle (PO creation, delivery/return-note signing)
--      is a known gap in the RPCs that mutate confirmed_items, so this report is necessarily scoped
--      to the PRE-CONFIRMATION pipeline only (New RFQ/Tendering/Extract PN/Ready For
--      Quotation/Sent To Vendor/Priced/Confirmed) — exactly the stages the user asked about.
--   2. status_logs has NO old/new-status pair — each row is just "entered item_status at
--      created_at." Consecutive rows frequently repeat the SAME status (e.g. re-sending an RFQ to
--      additional vendors re-logs status 237 "Sent To Vendor" without an actual stage change) —
--      verified live on quotation_item_id 77768 (five rows, four of them status 237 in a row).
--      Naively pairing consecutive rows would attribute that noise as a "transition." Consecutive
--      same-status rows are collapsed into one stage-entry (earliest created_at kept) before pairing.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_lifecycle_stage_durations(
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
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  WITH scoped_items AS (
    SELECT DISTINCT qi.quotation_item_id
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
      AND (v_branch_scope IS NULL OR qi.customer_id = ANY(v_branch_scope))
  ),
  logs AS (
    SELECT sl.quotation_item_id, sl.item_status, sl.created_at, sl.status_log_id
    FROM qvm_new_apps.status_logs sl
    JOIN scoped_items si ON si.quotation_item_id = sl.quotation_item_id
    WHERE sl.quotation_item_id IS NOT NULL
  ),
  numbered AS (
    SELECT
      quotation_item_id, item_status, created_at,
      lag(item_status) OVER (PARTITION BY quotation_item_id ORDER BY created_at, status_log_id) AS prev_status
    FROM logs
  ),
  grp AS (
    SELECT
      *,
      sum(CASE WHEN item_status IS DISTINCT FROM prev_status THEN 1 ELSE 0 END)
        OVER (PARTITION BY quotation_item_id ORDER BY created_at) AS grp_id
    FROM numbered
  ),
  collapsed AS (
    SELECT quotation_item_id, item_status, min(created_at) AS entered_at
    FROM grp
    GROUP BY quotation_item_id, grp_id, item_status
  ),
  seq AS (
    SELECT
      quotation_item_id, item_status, entered_at,
      lag(item_status) OVER (PARTITION BY quotation_item_id ORDER BY entered_at) AS prev_status,
      lag(entered_at) OVER (PARTITION BY quotation_item_id ORDER BY entered_at) AS prev_time
    FROM collapsed
  ),
  transitions AS (
    SELECT
      prev_status AS from_status,
      item_status AS to_status,
      extract(epoch FROM (entered_at - prev_time)) AS seconds
    FROM seq
    WHERE prev_status IS NOT NULL
  ),
  grand_total AS (
    SELECT NULLIF(sum(seconds), 0) AS total_seconds FROM transitions
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.total_hours DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      t.from_status,
      ld1.list_data AS from_label,
      t.to_status,
      ld2.list_data AS to_label,
      count(*) AS transition_count,
      round((sum(t.seconds) / 3600.0)::numeric, 1) AS total_hours,
      round((sum(t.seconds) / 3600.0 / count(*))::numeric, 1) AS avg_hours,
      round((sum(t.seconds) / gt.total_seconds * 100)::numeric, 1) AS pct_of_total
    FROM transitions t
    LEFT JOIN qvm_new_apps.list_data ld1 ON ld1.list_data_id = t.from_status
    LEFT JOIN qvm_new_apps.list_data ld2 ON ld2.list_data_id = t.to_status
    CROSS JOIN grand_total gt
    WHERE gt.total_seconds IS NOT NULL
    GROUP BY t.from_status, ld1.list_data, t.to_status, ld2.list_data, gt.total_seconds
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_lifecycle_stage_durations(integer, timestamptz, timestamptz) TO authenticated;
