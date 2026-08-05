-- FCM push notifications: device token registry, notification log, per-recipient read-state
-- (in-app inbox), and per-device delivery audit trail.
--
-- Sending is internal-staff-only and always scoped to the sender's own qvm_new_apps.user_data
-- .user_company: "send to all" means "all users in my company", not a true platform-wide
-- broadcast, and "send to a specific user" is rejected if that user isn't in the same company.
-- This mirrors the client_id-from-auth-user pattern already used by insurance_companies.

CREATE TABLE qvm_new_apps.device_tokens (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON DELETE CASCADE,
  token text NOT NULL,
  platform text NULL,
  is_active boolean NOT NULL DEFAULT true,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT device_tokens_token_unique UNIQUE (token)
);
CREATE INDEX device_tokens_user_id_idx ON qvm_new_apps.device_tokens(user_id) WHERE is_active;

CREATE TABLE qvm_new_apps.notifications (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  data jsonb NULL,
  target_type text NOT NULL CHECK (target_type IN ('all', 'user')),
  target_user_id uuid NULL REFERENCES qvm_new_apps.user_data(user_id) ON DELETE CASCADE,
  target_company_id integer NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  created_by uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notifications_target_shape CHECK (
    (target_type = 'user' AND target_user_id IS NOT NULL AND target_company_id IS NULL)
    OR
    (target_type = 'all' AND target_company_id IS NOT NULL AND target_user_id IS NULL)
  )
);

-- One row per actual recipient, written at send time — this IS the in-app inbox: listing a
-- user's notifications and computing their unread count is a plain filter on this table, with
-- no need to re-derive company membership (which could drift) after the fact.
CREATE TABLE qvm_new_apps.notification_reads (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  notification_id bigint NOT NULL REFERENCES qvm_new_apps.notifications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id) ON DELETE CASCADE,
  is_read boolean NOT NULL DEFAULT false,
  read_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_reads_unique UNIQUE (notification_id, user_id)
);
CREATE INDEX notification_reads_user_id_idx ON qvm_new_apps.notification_reads(user_id, is_read);

-- Per-token send attempt, written by the send-push-notification edge function (service role).
CREATE TABLE qvm_new_apps.notification_deliveries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  notification_id bigint NOT NULL REFERENCES qvm_new_apps.notifications(id) ON DELETE CASCADE,
  device_token_id bigint NOT NULL REFERENCES qvm_new_apps.device_tokens(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('sent', 'failed')),
  fcm_message_id text NULL,
  error_message text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notification_deliveries_notification_id_idx ON qvm_new_apps.notification_deliveries(notification_id);

ALTER TABLE qvm_new_apps.device_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.notification_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.notification_deliveries ENABLE ROW LEVEL SECURITY;

-- The send-push-notification edge function reads/writes these tables directly (not through an
-- RPC) using the service-role key — RLS bypass for service_role doesn't imply base table
-- privileges, so these need an explicit GRANT, same as appsheet_sync_logs/webhook_logs.
GRANT SELECT ON qvm_new_apps.notifications TO service_role;
GRANT SELECT, UPDATE ON qvm_new_apps.device_tokens TO service_role;
GRANT INSERT ON qvm_new_apps.notification_deliveries TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.notification_deliveries_id_seq TO service_role;

-- Every other access path goes through the SECURITY DEFINER RPCs below, not direct table grants.
CREATE POLICY device_tokens_select_own ON qvm_new_apps.device_tokens
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY notifications_select_internal ON qvm_new_apps.notifications
  FOR SELECT USING (qvm_new_apps.is_internal_user());
CREATE POLICY notification_reads_select_own ON qvm_new_apps.notification_reads
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY notification_deliveries_select_internal ON qvm_new_apps.notification_deliveries
  FOR SELECT USING (qvm_new_apps.is_internal_user());

-- Registers (or refreshes) the calling user's own device token. Per-device dedup: the same
-- token re-registering just bumps last_seen_at/reactivates it, it never creates a duplicate row.
-- A token can migrate to a different user (e.g. logout/login as someone else on the same
-- browser) — ON CONFLICT re-points ownership rather than erroring.
CREATE FUNCTION qvm_new_apps.register_device_token(p_token text, p_platform text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Token is required');
  END IF;

  INSERT INTO qvm_new_apps.device_tokens (user_id, token, platform, is_active, last_seen_at)
  VALUES (auth.uid(), btrim(p_token), p_platform, true, now())
  ON CONFLICT (token) DO UPDATE
    SET user_id = excluded.user_id,
        platform = excluded.platform,
        is_active = true,
        last_seen_at = now();

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.register_device_token(text, text) TO authenticated;

-- Internal-only. "All" means every user sharing the sender's own user_company — never a true
-- platform-wide broadcast. Fans out one notification_reads row per recipient at send time, then
-- fires the send-push-notification edge function (async via pg_net) to actually call FCM.
CREATE FUNCTION qvm_new_apps.send_notification_to_all(p_title text, p_body text, p_data jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
  v_notification_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_title IS NULL OR btrim(p_title) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Title and body are required');
  END IF;

  SELECT user_company INTO v_company_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  IF v_company_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client — contact an administrator');
  END IF;

  INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_company_id, created_by)
  VALUES (btrim(p_title), btrim(p_body), p_data, 'all', v_company_id, auth.uid())
  RETURNING id INTO v_notification_id;

  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  SELECT v_notification_id, ud.user_id
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_company = v_company_id;

  PERFORM net.http_post(
    url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.send_notification_to_all(text, text, jsonb) TO authenticated;

-- Internal-only. Rejects targeting a user outside the sender's own company — an internal admin
-- can't reach into another client's users this way, same boundary as the "all" case above.
CREATE FUNCTION qvm_new_apps.send_notification_to_user(p_user_id uuid, p_title text, p_body text, p_data jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_sender_company_id integer;
  v_target_company_id integer;
  v_notification_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_title IS NULL OR btrim(p_title) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Title and body are required');
  END IF;
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Target user is required');
  END IF;

  SELECT user_company INTO v_sender_company_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  SELECT user_company INTO v_target_company_id FROM qvm_new_apps.user_data WHERE user_id = p_user_id;

  IF v_sender_company_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client — contact an administrator');
  END IF;
  IF v_target_company_id IS NULL OR v_target_company_id != v_sender_company_id THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Target user is not in your company');
  END IF;

  INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
  VALUES (btrim(p_title), btrim(p_body), p_data, 'user', p_user_id, auth.uid())
  RETURNING id INTO v_notification_id;

  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  VALUES (v_notification_id, p_user_id);

  PERFORM net.http_post(
    url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.send_notification_to_user(uuid, text, text, jsonb) TO authenticated;

-- In-app inbox: the caller's own notifications, newest first.
CREATE FUNCTION qvm_new_apps.list_my_notifications(p_limit integer DEFAULT 50)
 RETURNS TABLE(id bigint, title text, body text, data jsonb, is_read boolean, read_at timestamptz, created_at timestamptz)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT n.id, n.title, n.body, n.data, r.is_read, r.read_at, n.created_at
  FROM qvm_new_apps.notification_reads r
  JOIN qvm_new_apps.notifications n ON n.id = r.notification_id
  WHERE r.user_id = auth.uid()
  ORDER BY n.created_at DESC
  LIMIT p_limit;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_my_notifications(integer) TO authenticated;

CREATE FUNCTION qvm_new_apps.mark_notification_read(p_notification_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  UPDATE qvm_new_apps.notification_reads
  SET is_read = true, read_at = now()
  WHERE notification_id = p_notification_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Notification not found');
  END IF;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.mark_notification_read(bigint) TO authenticated;
