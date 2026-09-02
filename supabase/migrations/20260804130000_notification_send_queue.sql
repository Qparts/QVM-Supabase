-- Queue the actual FCM sends instead of resolving+sending every recipient's device token in one
-- edge function invocation — a company-wide broadcast could have hundreds of tokens, and sending
-- them all sequentially in a single request risks the edge function's execution time limit.
--
-- notification_deliveries now doubles as the send queue: send_notification_to_all/_to_user
-- enqueue one 'pending' row per active device token in the SAME transaction as creating the
-- notification (so the queue is never partially populated), then kick off processing. The edge
-- function claims a small batch at a time (claim_notification_delivery_batch, using
-- FOR UPDATE SKIP LOCKED so nothing can be double-claimed), sends just that batch, and — instead
-- of looping over the rest itself — asks Postgres to fire the next hop via
-- trigger_next_notification_batch, which re-invokes the same edge function through pg_net (async,
-- fire-and-forget) only if pending rows remain. Each individual invocation's work is bounded by
-- the batch size, however many recipients the whole notification has.

ALTER TABLE qvm_new_apps.notification_deliveries
  DROP CONSTRAINT notification_deliveries_status_check;
ALTER TABLE qvm_new_apps.notification_deliveries
  ADD CONSTRAINT notification_deliveries_status_check CHECK (status IN ('pending', 'sending', 'sent', 'failed'));
ALTER TABLE qvm_new_apps.notification_deliveries
  ALTER COLUMN status SET DEFAULT 'pending';

CREATE INDEX notification_deliveries_pending_idx
  ON qvm_new_apps.notification_deliveries (notification_id)
  WHERE status = 'pending';

-- The edge function now UPDATEs existing queued rows (claim -> sent/failed) rather than
-- INSERTing one per send; enqueueing itself happens inside the two RPCs below (SECURITY DEFINER,
-- so they insert as their owner, not as the caller). SELECT is required too: PostgREST's UPDATE
-- returns the affected rows by default, which needs read access even though the caller only
-- issued a write.
GRANT SELECT, UPDATE ON qvm_new_apps.notification_deliveries TO service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.send_notification_to_all(p_title text, p_body text, p_data jsonb DEFAULT NULL)
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

  -- Enqueue every active device token of every recipient as one pending delivery row, up front,
  -- in this same transaction — the queue either fully exists or (on rollback) doesn't at all.
  INSERT INTO qvm_new_apps.notification_deliveries (notification_id, device_token_id, status)
  SELECT v_notification_id, dt.id, 'pending'
  FROM qvm_new_apps.device_tokens dt
  JOIN qvm_new_apps.user_data ud ON ud.user_id = dt.user_id
  WHERE ud.user_company = v_company_id AND dt.is_active;

  PERFORM net.http_post(
    url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.send_notification_to_user(p_user_id uuid, p_title text, p_body text, p_data jsonb DEFAULT NULL)
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

  INSERT INTO qvm_new_apps.notification_deliveries (notification_id, device_token_id, status)
  SELECT v_notification_id, dt.id, 'pending'
  FROM qvm_new_apps.device_tokens dt
  WHERE dt.user_id = p_user_id AND dt.is_active;

  PERFORM net.http_post(
    url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

-- Atomically claims up to p_batch_size still-pending rows for one notification and flips them to
-- 'sending' so a concurrent/duplicate hop can't grab the same rows (FOR UPDATE SKIP LOCKED means
-- an overlapping call just skips whatever this one already has locked, instead of blocking).
CREATE FUNCTION qvm_new_apps.claim_notification_delivery_batch(p_notification_id bigint, p_batch_size integer DEFAULT 50)
 RETURNS TABLE(delivery_id bigint, device_token_id bigint, token text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH claimed AS (
    UPDATE qvm_new_apps.notification_deliveries nd
    SET status = 'sending'
    WHERE nd.id IN (
      SELECT id FROM qvm_new_apps.notification_deliveries
      WHERE notification_id = p_notification_id AND status = 'pending'
      ORDER BY id
      LIMIT p_batch_size
      FOR UPDATE SKIP LOCKED
    )
    RETURNING nd.id, nd.device_token_id
  )
  SELECT c.id, dt.id, dt.token
  FROM claimed c
  JOIN qvm_new_apps.device_tokens dt ON dt.id = c.device_token_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.claim_notification_delivery_batch(bigint, integer) TO service_role;

-- Called by the edge function after it finishes a batch — fires the next hop only if there's
-- still work queued, so a fully-drained notification doesn't spawn one extra no-op invocation.
CREATE FUNCTION qvm_new_apps.trigger_next_notification_batch(p_notification_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM qvm_new_apps.notification_deliveries
    WHERE notification_id = p_notification_id AND status = 'pending'
  ) THEN
    PERFORM net.http_post(
      url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('notification_id', p_notification_id)
    );
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.trigger_next_notification_batch(bigint) TO service_role;
