-- A vendor whose email is already somebody's login still gets a login of its own.
--
-- ensure_vendor_login gave up when the vendor's address already belonged to a user — an internal
-- person, or the admin of a duplicate vendor row — and that vendor was left with no way in. The
-- rule now: try the address as given; if taken, the same address with ".vendor" before the @;
-- if that is taken too (several vendors filed under one shared address), ".vendor<vendor id>".
-- Everything else is as before: a Vendor Admin, password 123456, created only when the vendor
-- has no vendor login at all.

CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_vendor_login(p_vendor_id integer, p_password text DEFAULT '123456'::text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'auth', 'extensions', 'public'
AS $function$
DECLARE
  v_email text; v_name text; v_uid uuid; v_role integer;
  v_local text; v_domain text; v_candidate text; v_try text[];
BEGIN
  SELECT NULLIF(lower(trim(email)), ''), vendor_name INTO v_email, v_name
    FROM qvm_new_apps.vendors WHERE vendor_id = p_vendor_id;
  IF v_email IS NULL OR position('@' IN v_email) = 0 THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.user_data
              WHERE user_type = 205 AND user_vendor = p_vendor_id AND deleted_at IS NULL) THEN
    RETURN NULL;
  END IF;

  SELECT ld.list_data_id INTO v_role
    FROM qvm_new_apps.list_data ld JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
   WHERE l.list_name = 'user_role' AND ld.list_data = 'Vendor Admin' LIMIT 1;
  IF v_role IS NULL THEN RETURN NULL; END IF;

  v_local  := split_part(v_email, '@', 1);
  v_domain := split_part(v_email, '@', 2);
  v_try := ARRAY[v_email, v_local || '.vendor@' || v_domain, v_local || '.vendor' || p_vendor_id || '@' || v_domain];
  FOREACH v_candidate IN ARRAY v_try LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_candidate)
          AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data WHERE lower(btrim(email)) = v_candidate);
    v_candidate := NULL;
  END LOOP;
  IF v_candidate IS NULL THEN RETURN NULL; END IF;

  v_uid := gen_random_uuid();
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    v_candidate, extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false,
    '', '', '', '', '', '', '', ''
  );
  INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  VALUES (v_uid::text, v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', v_candidate, 'email_verified', true, 'phone_verified', false),
    'email', now(), now());
  INSERT INTO qvm_new_apps.user_data (user_id, email, user_name, user_type, user_role, user_vendor, notification_method)
  VALUES (v_uid, v_candidate, COALESCE(v_name, v_candidate), 205, v_role, p_vendor_id, 'email');
  RETURN v_uid;
END;
$function$;
