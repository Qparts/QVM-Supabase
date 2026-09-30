-- Some pages are the Qparts Admin's, and the sidebar knows it too.
--
-- On request (2026-09-30): Send Notification, AI settings, the Integrations Catalogue and
-- Users & Permissions are the Qparts Admin's; AI Credit and Account Managers are the Qparts
-- Admin's and the Company Admin's; Languages stays the Qparts Admin's. The page defaults that gave
-- other roles those pages are withdrawn, and the write paths of the pages that were open to any
-- internal user or any company admin are closed to the Qparts Admin. The pricing rules and the
-- team permissions screens keep their own gates.

set search_path to qvm_new_apps, public;

delete from qvm_new_apps.permission_role_defaults
 where nav_id in ('send-notification', 'user-mgmt', 'languages', 'ai-settings', 'integrations-admin');
delete from qvm_new_apps.permission_role_defaults
 where nav_id in ('ai-credit', 'account-managers')
   and role_id <> qvm_new_apps.company_admin_role_id();

CREATE OR REPLACE FUNCTION qvm_new_apps.send_notification_to_all(p_title text, p_body text, p_data jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company_id integer;
  v_notification_id bigint;
BEGIN
  -- Send Notification is the Qparts Admin's page (2026-09-30).
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
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
    url := 'https://exizrhlkxoqljiypzwyx.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.send_notification_to_user(p_user_id uuid, p_title text, p_body text, p_data jsonb DEFAULT NULL::jsonb)
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
  -- Send Notification is the Qparts Admin's page (2026-09-30).
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
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

  v_notification_id := qvm_new_apps.dispatch_push_to_user(p_user_id, p_title, p_body, p_data);

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.service_credential_save(p_service text, p_key text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_key text := nullif(btrim(coalesce(p_key, '')), '');
begin
  -- AI settings is the Qparts Admin's page (2026-09-30).
  if not qvm_new_apps.is_qparts_admin(auth.uid()) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_service,'')), '') is null then
    return jsonb_build_object('status', false, 'message', 'اسم الخدمة مطلوب', 'data', null);
  end if;

  insert into qvm_new_apps.service_credentials (service, api_key, extra, updated_by)
  values (btrim(p_service), v_key, p_extra, auth.uid())
  on conflict (service) do update set
    -- Blank means «leave the key alone», not «erase it»: nobody can read it back to retype it.
    api_key    = coalesce(excluded.api_key, qvm_new_apps.service_credentials.api_key),
    extra      = coalesce(excluded.extra, qvm_new_apps.service_credentials.extra),
    updated_by = auth.uid(),
    updated_at = now();

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_company_permissions(p_company_id integer, p_cells jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_count int;
BEGIN
  -- Users & Permissions is the Qparts Admin's page (2026-09-30).
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF jsonb_typeof(p_cells) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Expected a list of cells');
  END IF;

  -- The role is still checked: it is a real thing with an id, and a company may only set rules for
  -- the roles it assigns. The page is not — it is the sidebar's own name for a screen, and a name
  -- that matches nothing is a row nothing reads.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_cells) c
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles pr
                        WHERE pr.role_id = (c->>'role_id')::int AND pr.is_assignable)
        OR btrim(COALESCE(c->>'nav_id', '')) = ''
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role cannot be given permissions');
  END IF;

  INSERT INTO qvm_new_apps.company_role_permissions
    (company_id, role_id, nav_id, can_view, can_create, can_update, can_delete, updated_by, updated_at)
  SELECT p_company_id,
         (c->>'role_id')::int,
         btrim(c->>'nav_id'),
         COALESCE((c->>'view')::boolean, false),
         -- An action on a page nobody may open is not a permission, it is a contradiction.
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'create')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'update')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'delete')::boolean, false),
         v_uid, now()
  FROM jsonb_array_elements(p_cells) c
  ON CONFLICT (company_id, role_id, nav_id) DO UPDATE
    SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create,
        can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete,
        updated_by = EXCLUDED.updated_by, updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('saved', v_count));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_reset_company_permissions(p_company_id integer, p_role_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_count int;
BEGIN
  -- Users & Permissions is the Qparts Admin's page (2026-09-30).
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  DELETE FROM qvm_new_apps.company_role_permissions
   WHERE company_id = p_company_id AND (p_role_id IS NULL OR role_id = p_role_id);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('cleared', v_count));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_company_approval_levels(p_company_id integer, p_levels jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  -- Users & Permissions is the Qparts Admin's page (2026-09-30).
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Not allowed to set the approval levels for this company';
  END IF;

  DELETE FROM qvm_new_apps.approval_levels WHERE company_id = p_company_id;

  INSERT INTO qvm_new_apps.approval_levels (company_id, level_no, user_id)
  SELECT p_company_id, ord::integer, (x->>'user_id')::uuid
    FROM jsonb_array_elements(COALESCE(p_levels, '[]'::jsonb)) WITH ORDINALITY AS e(x, ord)
   WHERE COALESCE(btrim(x->>'user_id'), '') <> '';

  RETURN jsonb_build_object('status', 'success',
                            'levels', (SELECT count(*) FROM qvm_new_apps.approval_levels
                                        WHERE company_id = p_company_id));
END;
$function$;
