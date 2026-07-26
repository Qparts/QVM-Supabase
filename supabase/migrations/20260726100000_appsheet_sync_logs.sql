-- QNEW-65: audit trail for every outbound AppSheet sync call. Mirrors the qvm_new_apps.webhook_logs
-- pattern (RLS + service-role-only writes + paginated list RPC), but writes in two phases: a
-- 'pending' row before calling AppSheet, then an update with the outcome after - so a request that
-- crashes mid-flight still leaves a row showing what was attempted.
CREATE TABLE qvm_new_apps.appsheet_sync_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  action text NOT NULL CHECK (action IN ('add_item', 'update_price', 'update_status')),
  source_table text NOT NULL,
  record_id bigint NOT NULL,
  payload_sent jsonb,
  appsheet_response jsonb,
  http_status integer,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'success', 'error', 'skipped')),
  error_message text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz
);

CREATE INDEX appsheet_sync_logs_action_idx ON qvm_new_apps.appsheet_sync_logs (action, created_at DESC);
CREATE INDEX appsheet_sync_logs_record_id_idx ON qvm_new_apps.appsheet_sync_logs (record_id);

ALTER TABLE qvm_new_apps.appsheet_sync_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY appsheet_sync_logs_select_internal ON qvm_new_apps.appsheet_sync_logs
  FOR SELECT
  USING (qvm_new_apps.is_internal_user());

-- No INSERT/UPDATE/DELETE policies for anon/authenticated: only the service-role key (used by the
-- AppSheet-sync edge functions) writes here, and service_role bypasses RLS entirely.

GRANT INSERT, UPDATE, SELECT ON qvm_new_apps.appsheet_sync_logs TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.appsheet_sync_logs_id_seq TO service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_appsheet_sync_logs(
  p_action text DEFAULT NULL,
  p_source_table text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id bigint,
  action text,
  source_table text,
  record_id bigint,
  payload_sent jsonb,
  appsheet_response jsonb,
  http_status integer,
  status text,
  error_message text,
  created_by uuid,
  created_at timestamptz,
  responded_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT
    l.id, l.action, l.source_table, l.record_id, l.payload_sent, l.appsheet_response,
    l.http_status, l.status, l.error_message, l.created_by, l.created_at, l.responded_at,
    count(*) OVER ()::bigint AS total_count
  FROM qvm_new_apps.appsheet_sync_logs l
  WHERE (p_action IS NULL OR l.action = p_action)
    AND (p_source_table IS NULL OR l.source_table = p_source_table)
    AND (p_status IS NULL OR l.status = p_status)
    AND (p_date_from IS NULL OR l.created_at >= p_date_from)
    AND (p_date_to IS NULL OR l.created_at <= p_date_to)
  ORDER BY l.created_at DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 200)
  OFFSET GREATEST(p_offset, 0);
END;
$function$;

REVOKE EXECUTE ON FUNCTION qvm_new_apps.list_appsheet_sync_logs(text, text, text, timestamptz, timestamptz, integer, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_appsheet_sync_logs(text, text, text, timestamptz, timestamptz, integer, integer) TO authenticated;
