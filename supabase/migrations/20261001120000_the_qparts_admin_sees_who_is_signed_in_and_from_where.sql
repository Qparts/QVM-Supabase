-- The Qparts Admin sees who is signed in, and from where.
--
-- A new page, Active Sessions & Devices, lists every account on the platform with how many
-- sessions it holds right now, and opens one to its sessions — when each began, when it was last
-- used, from which browser and address — and the devices that registered for notifications. Auth
-- keeps the sessions; the app keeps the device tokens; both are read here, for the Qparts Admin
-- alone.

-- A session counts as live while it has not run out, still holds a refresh token that was not
-- revoked (a session with no token rows at all is the newer, stateless kind, and counts too), and
-- was used in the last 30 days — the same window the profile's own-sessions card calls «currently
-- signed in» (get_my_active_sessions). Auth keeps a session row until it is signed out, so
-- without the window every browser ever used would still read as signed in.
CREATE OR REPLACE FUNCTION qvm_new_apps.session_is_live(p_session auth.sessions)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT (p_session.not_after IS NULL OR p_session.not_after > now())
     AND COALESCE(p_session.refreshed_at AT TIME ZONE 'UTC', p_session.updated_at) > now() - interval '30 days'
     AND (EXISTS (SELECT 1 FROM auth.refresh_tokens r WHERE r.session_id = p_session.id AND NOT r.revoked)
          OR NOT EXISTS (SELECT 1 FROM auth.refresh_tokens r WHERE r.session_id = p_session.id));
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.session_is_live(auth.sessions) FROM PUBLIC, anon, authenticated;

-- Every account, with its role, where it belongs, when it last signed in, how many live sessions
-- it holds and when one was last used, and how many devices it registered.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_users_with_sessions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin sees sessions'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', ud.user_id,
             'user_name', ud.user_name,
             'email', COALESCE(au.email, ud.email),
             'user_type', ud.user_type, 'user_type_name', ut.list_data,
             'user_role', ud.user_role, 'user_role_name', ur.list_data,
             'company_name', co.list_data,
             'vendor_name', v.vendor_name,
             'created_at', au.created_at,
             'last_sign_in_at', au.last_sign_in_at,
             'banned_until', au.banned_until,
             'has_auth_user', au.id IS NOT NULL,
             'live_sessions', (SELECT count(*) FROM auth.sessions s WHERE s.user_id = ud.user_id AND qvm_new_apps.session_is_live(s)),
             'total_sessions', (SELECT count(*) FROM auth.sessions s WHERE s.user_id = ud.user_id),
             'last_seen_at', (SELECT max(COALESCE(s.refreshed_at AT TIME ZONE 'UTC', s.updated_at)) FROM auth.sessions s WHERE s.user_id = ud.user_id),
             'active_devices', (SELECT count(*) FROM qvm_new_apps.device_tokens d WHERE d.user_id = ud.user_id AND d.is_active),
             'total_devices', (SELECT count(*) FROM qvm_new_apps.device_tokens d WHERE d.user_id = ud.user_id)
           ) ORDER BY (SELECT max(COALESCE(s.refreshed_at AT TIME ZONE 'UTC', s.updated_at)) FROM auth.sessions s WHERE s.user_id = ud.user_id) DESC NULLS LAST,
                      ud.user_name)
      FROM qvm_new_apps.user_data ud
      LEFT JOIN auth.users au ON au.id = ud.user_id
      LEFT JOIN qvm_new_apps.list_data ut ON ut.list_data_id = ud.user_type
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = ud.user_role
      LEFT JOIN qvm_new_apps.list_data co ON co.list_data_id = ud.user_company
      LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = ud.user_vendor
     WHERE ud.deleted_at IS NULL), '[]'::jsonb);
END $function$;

-- One account's sessions, newest activity first, and its devices.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_user_sessions(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin sees sessions'; END IF;
  RETURN jsonb_build_object(
    'sessions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'session_id', s.id,
               'created_at', s.created_at,
               'last_seen_at', COALESCE(s.refreshed_at AT TIME ZONE 'UTC', s.updated_at),
               'not_after', s.not_after,
               'aal', s.aal::text,
               'user_agent', s.user_agent,
               'ip', host(s.ip),
               'is_live', qvm_new_apps.session_is_live(s),
               -- The admin's own session, when they look at themselves.
               'is_current', s.id::text = (auth.jwt() ->> 'session_id')
             ) ORDER BY COALESCE(s.refreshed_at AT TIME ZONE 'UTC', s.updated_at) DESC)
        FROM auth.sessions s WHERE s.user_id = p_user_id), '[]'::jsonb),
    'devices', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'device_id', d.id, 'platform', d.platform, 'is_active', d.is_active,
               'last_seen_at', d.last_seen_at, 'created_at', d.created_at
             ) ORDER BY d.is_active DESC, d.last_seen_at DESC NULLS LAST)
        FROM qvm_new_apps.device_tokens d WHERE d.user_id = p_user_id), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.admin_users_with_sessions()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_users_with_sessions() $function$;

CREATE OR REPLACE FUNCTION public.admin_user_sessions(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_user_sessions(p_user_id) $function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_users_with_sessions() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_user_sessions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_users_with_sessions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_user_sessions(uuid) TO authenticated;
