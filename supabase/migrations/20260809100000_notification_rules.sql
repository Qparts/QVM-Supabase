-- QNEW-99 Phase 1: admin-configurable notification rules — for each order status, an admin picks
-- the message, recipient, and channel(s), no code deploy needed. trigger_type/recipient_type are
-- plain text (not a CHECK-constrained enum) because the ticket explicitly requires new trigger
-- types (mention, reassignment, future Workflow Engine actions) to be addable without a schema
-- change — validity is enforced in the RPCs below instead.
CREATE TABLE qvm_new_apps.notification_rules (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trigger_type text NOT NULL,
  trigger_status_id integer NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  trigger_gate_key text NULL,
  delay_hours integer NOT NULL DEFAULT 0,
  recipient_type text NOT NULL,
  recipient_role_id integer NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  message_template text NOT NULL,
  channels text[] NOT NULL DEFAULT ARRAY['browser_push'],
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

ALTER TABLE qvm_new_apps.notification_rules ENABLE ROW LEVEL SECURITY;

CREATE POLICY notification_rules_select ON qvm_new_apps.notification_rules
  FOR SELECT USING (qvm_new_apps.is_internal_user());

CREATE TABLE qvm_new_apps.notification_rules_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id bigint NULL,
  actor uuid,
  action text NOT NULL,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE qvm_new_apps.notification_rules_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY notification_rules_audit_select ON qvm_new_apps.notification_rules_audit
  FOR SELECT USING (qvm_new_apps.is_internal_user());

CREATE FUNCTION qvm_new_apps.list_notification_rules()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', r.id,
           'trigger_type', r.trigger_type,
           'trigger_status_id', r.trigger_status_id,
           'trigger_status_name', ts.list_data,
           'trigger_gate_key', r.trigger_gate_key,
           'delay_hours', r.delay_hours,
           'recipient_type', r.recipient_type,
           'recipient_role_id', r.recipient_role_id,
           'recipient_role_name', rr.list_data,
           'message_template', r.message_template,
           'channels', r.channels,
           'is_active', r.is_active,
           'created_at', r.created_at,
           'updated_at', r.updated_at
         ) ORDER BY r.trigger_status_id NULLS LAST, r.id), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.notification_rules r
  LEFT JOIN qvm_new_apps.list_data ts ON ts.list_data_id = r.trigger_status_id
  LEFT JOIN qvm_new_apps.list_data rr ON rr.list_data_id = r.recipient_role_id;

  RETURN v_result;
END;
$function$;

CREATE FUNCTION qvm_new_apps.create_notification_rule(
  p_trigger_type text,
  p_trigger_status_id integer,
  p_trigger_gate_key text,
  p_delay_hours integer,
  p_recipient_type text,
  p_recipient_role_id integer,
  p_message_template text,
  p_channels text[]
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_trigger_type NOT IN ('status_change', 'gate_condition') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid trigger type');
  END IF;
  IF p_trigger_type = 'status_change' AND p_trigger_status_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A status is required for a status-change trigger');
  END IF;
  IF p_trigger_type = 'gate_condition' AND (p_trigger_gate_key IS NULL OR btrim(p_trigger_gate_key) = '') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A gate condition key is required');
  END IF;
  IF p_recipient_type NOT IN ('client', 'vendor', 'internal_role') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid recipient type');
  END IF;
  IF p_recipient_type = 'internal_role' AND p_recipient_role_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A role is required for an internal recipient');
  END IF;
  IF p_message_template IS NULL OR btrim(p_message_template) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Message template is required');
  END IF;

  INSERT INTO qvm_new_apps.notification_rules (
    trigger_type, trigger_status_id, trigger_gate_key, delay_hours,
    recipient_type, recipient_role_id, message_template, channels,
    created_by, updated_by
  ) VALUES (
    p_trigger_type, p_trigger_status_id, p_trigger_gate_key, COALESCE(p_delay_hours, 0),
    p_recipient_type, p_recipient_role_id, btrim(p_message_template), COALESCE(p_channels, ARRAY['browser_push']),
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_id;

  INSERT INTO qvm_new_apps.notification_rules_audit (rule_id, actor, action, old_value, new_value)
  VALUES (v_id, auth.uid(), 'create', NULL, to_jsonb((SELECT r FROM qvm_new_apps.notification_rules r WHERE r.id = v_id)));

  RETURN jsonb_build_object('status', 'success', 'id', v_id);
END;
$function$;

CREATE FUNCTION qvm_new_apps.update_notification_rule(
  p_id bigint,
  p_trigger_type text,
  p_trigger_status_id integer,
  p_trigger_gate_key text,
  p_delay_hours integer,
  p_recipient_type text,
  p_recipient_role_id integer,
  p_message_template text,
  p_channels text[]
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_old jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_trigger_type NOT IN ('status_change', 'gate_condition') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid trigger type');
  END IF;
  IF p_trigger_type = 'status_change' AND p_trigger_status_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A status is required for a status-change trigger');
  END IF;
  IF p_recipient_type NOT IN ('client', 'vendor', 'internal_role') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid recipient type');
  END IF;
  IF p_recipient_type = 'internal_role' AND p_recipient_role_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A role is required for an internal recipient');
  END IF;
  IF p_message_template IS NULL OR btrim(p_message_template) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Message template is required');
  END IF;

  SELECT to_jsonb(r) INTO v_old FROM qvm_new_apps.notification_rules r WHERE r.id = p_id;
  IF v_old IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Rule not found');
  END IF;

  UPDATE qvm_new_apps.notification_rules SET
    trigger_type = p_trigger_type,
    trigger_status_id = p_trigger_status_id,
    trigger_gate_key = p_trigger_gate_key,
    delay_hours = COALESCE(p_delay_hours, 0),
    recipient_type = p_recipient_type,
    recipient_role_id = p_recipient_role_id,
    message_template = btrim(p_message_template),
    channels = COALESCE(p_channels, ARRAY['browser_push']),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = p_id;

  INSERT INTO qvm_new_apps.notification_rules_audit (rule_id, actor, action, old_value, new_value)
  VALUES (p_id, auth.uid(), 'update', v_old, to_jsonb((SELECT r FROM qvm_new_apps.notification_rules r WHERE r.id = p_id)));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE FUNCTION qvm_new_apps.toggle_notification_rule(p_id bigint, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_old jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT to_jsonb(r) INTO v_old FROM qvm_new_apps.notification_rules r WHERE r.id = p_id;
  IF v_old IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Rule not found');
  END IF;

  UPDATE qvm_new_apps.notification_rules
  SET is_active = p_is_active, updated_at = now(), updated_by = auth.uid()
  WHERE id = p_id;

  INSERT INTO qvm_new_apps.notification_rules_audit (rule_id, actor, action, old_value, new_value)
  VALUES (p_id, auth.uid(), 'toggle', v_old, to_jsonb((SELECT r FROM qvm_new_apps.notification_rules r WHERE r.id = p_id)));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.list_notification_rules() FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.create_notification_rule(text, integer, text, integer, text, integer, text, text[]) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.update_notification_rule(bigint, text, integer, text, integer, text, integer, text, text[]) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.toggle_notification_rule(bigint, boolean) FROM public, anon;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_notification_rules() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_notification_rule(text, integer, text, integer, text, integer, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.update_notification_rule(bigint, text, integer, text, integer, text, integer, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.toggle_notification_rule(bigint, boolean) TO authenticated;
