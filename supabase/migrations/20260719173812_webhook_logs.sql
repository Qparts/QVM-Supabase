-- Records every "Send RFQ" / "Send PO" webhook attempt for observability, and gives the admin
-- panel a way to browse them. Written exclusively by the send_rfq_webhook / send_po_webhook edge
-- functions using the service-role key (so RLS only needs to gate reads).
CREATE TABLE qvm_new_apps.webhook_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trigger_type text NOT NULL CHECK (trigger_type IN ('send_rfq', 'send_po')),
  reference_id integer NOT NULL,
  request_url text NOT NULL,
  request_payload jsonb NOT NULL,
  response_status integer,
  response_body text,
  status text NOT NULL CHECK (status IN ('success', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX webhook_logs_trigger_type_idx ON qvm_new_apps.webhook_logs (trigger_type, created_at DESC);
CREATE INDEX webhook_logs_reference_id_idx ON qvm_new_apps.webhook_logs (reference_id);

ALTER TABLE qvm_new_apps.webhook_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY webhook_logs_select_internal ON qvm_new_apps.webhook_logs
  FOR SELECT
  USING (qvm_new_apps.is_internal_user());

-- No INSERT/UPDATE/DELETE policies for anon/authenticated: only the service-role key (used by the
-- webhook edge functions) can write, and service_role bypasses RLS entirely.

CREATE OR REPLACE FUNCTION qvm_new_apps.list_webhook_logs(
  p_trigger_type text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id bigint,
  trigger_type text,
  reference_id integer,
  request_url text,
  request_payload jsonb,
  response_status integer,
  response_body text,
  status text,
  created_at timestamptz,
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
    l.id, l.trigger_type, l.reference_id, l.request_url, l.request_payload,
    l.response_status, l.response_body, l.status, l.created_at,
    count(*) OVER ()::bigint AS total_count
  FROM qvm_new_apps.webhook_logs l
  WHERE (p_trigger_type IS NULL OR l.trigger_type = p_trigger_type)
    AND (p_status IS NULL OR l.status = p_status)
  ORDER BY l.created_at DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 200)
  OFFSET GREATEST(p_offset, 0);
END;
$function$;
