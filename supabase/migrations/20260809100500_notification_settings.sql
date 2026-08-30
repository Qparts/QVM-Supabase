-- QNEW-99 Phase 1: notification settings (webhook base URL, WhatsApp/email credentials, default
-- companion channel) are configured per CLIENT COMPANY, not system-wide — company_id is the same
-- qvm_new_apps.list_data(list_data_id) space under list_id=1 already used by client_branches and
-- insurance_companies.client_id (the "clients" list; get_clients_rows() lists its rows). One row
-- per company, created on first save (upsert) — there's no seed/default row.
--
-- company_id is derived server-side from the caller's own qvm_new_apps.user_data.user_company —
-- never passed from the client — mirroring create_insurance_company's exact pattern
-- (20260804090000_insurance_company_client_from_auth_user.sql): the admin's own account is already
-- tied to one client company, so there's nothing to pick from a dropdown.
--
-- Gated to the "Qparts Admin" role specifically — this table holds real API credentials, stricter
-- than the general is_internal_user() gate used for notification_rules CRUD.
CREATE TABLE qvm_new_apps.notification_settings (
  company_id integer PRIMARY KEY REFERENCES qvm_new_apps.list_data(list_data_id),
  webhook_base_url text NULL,
  whatsapp_api_key text NULL,
  whatsapp_sender_id text NULL,
  email_from_name text NULL,
  email_from_address text NULL,
  default_companion_channel text NULL CHECK (default_companion_channel IN ('whatsapp', 'email', 'webhook')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

ALTER TABLE qvm_new_apps.notification_settings ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION qvm_new_apps.is_qparts_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    JOIN qvm_new_apps.lists l ON l.list_id = ur.list_id AND l.list_name = 'user_role'
    WHERE u.user_id = auth.uid() AND u.user_type = 185 AND ur.list_data = 'Qparts Admin'
  );
$function$;

CREATE POLICY notification_settings_select ON qvm_new_apps.notification_settings
  FOR SELECT USING (qvm_new_apps.is_qparts_admin());

-- Returns settings for the caller's own company (via user_data.user_company), including its
-- display name, or an all-null object (still carrying company_id/company_name) if that company
-- hasn't saved any settings yet — the frontend renders an empty, ready-to-fill form either way.
CREATE FUNCTION qvm_new_apps.get_notification_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
  v_company_name text;
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT user_company INTO v_company_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'Your account has no associated client company';
  END IF;
  SELECT list_data INTO v_company_name FROM qvm_new_apps.list_data WHERE list_data_id = v_company_id;

  SELECT to_jsonb(s) || jsonb_build_object('company_name', v_company_name) INTO v_result
  FROM qvm_new_apps.notification_settings s WHERE s.company_id = v_company_id;
  IF v_result IS NULL THEN
    v_result := jsonb_build_object(
      'company_id', v_company_id, 'company_name', v_company_name,
      'webhook_base_url', NULL, 'whatsapp_api_key', NULL, 'whatsapp_sender_id', NULL,
      'email_from_name', NULL, 'email_from_address', NULL, 'default_companion_channel', NULL,
      'updated_at', NULL
    );
  END IF;
  RETURN v_result;
END;
$function$;

CREATE FUNCTION qvm_new_apps.update_notification_settings(
  p_webhook_base_url text,
  p_whatsapp_api_key text,
  p_whatsapp_sender_id text,
  p_email_from_name text,
  p_email_from_address text,
  p_default_companion_channel text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT user_company INTO v_company_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  IF v_company_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client company');
  END IF;
  IF p_default_companion_channel IS NOT NULL AND p_default_companion_channel NOT IN ('whatsapp', 'email', 'webhook') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid default companion channel');
  END IF;

  INSERT INTO qvm_new_apps.notification_settings (
    company_id, webhook_base_url, whatsapp_api_key, whatsapp_sender_id,
    email_from_name, email_from_address, default_companion_channel, updated_by
  ) VALUES (
    v_company_id, NULLIF(btrim(p_webhook_base_url), ''), NULLIF(btrim(p_whatsapp_api_key), ''), NULLIF(btrim(p_whatsapp_sender_id), ''),
    NULLIF(btrim(p_email_from_name), ''), NULLIF(btrim(p_email_from_address), ''), p_default_companion_channel, auth.uid()
  )
  ON CONFLICT (company_id) DO UPDATE SET
    webhook_base_url = EXCLUDED.webhook_base_url,
    whatsapp_api_key = EXCLUDED.whatsapp_api_key,
    whatsapp_sender_id = EXCLUDED.whatsapp_sender_id,
    email_from_name = EXCLUDED.email_from_name,
    email_from_address = EXCLUDED.email_from_address,
    default_companion_channel = EXCLUDED.default_companion_channel,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.get_notification_settings() FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.update_notification_settings(text, text, text, text, text, text) FROM public, anon;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_notification_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.update_notification_settings(text, text, text, text, text, text) TO authenticated;
