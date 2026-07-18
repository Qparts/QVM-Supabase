-- Synced from QVM/test branch applied migration history (version 20260717192553, name: qvm_vendor_default_login_provisioning)

-- QNEW: every vendor should be able to log in with the default password 123456.
-- ensure_vendor_login creates a proper GoTrue login (auth.users + auth.identities + user_data)
-- for a vendor that has an email but no login yet. Idempotent + safe: returns NULL (no-op) when
-- the vendor has no email, already has a login, or the email is already taken by another auth user.
CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_vendor_login(p_vendor_id integer, p_password text DEFAULT '123456')
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','auth','extensions','public'
AS $$
DECLARE
  v_email text;
  v_name  text;
  v_uid   uuid;
  v_role  integer;
BEGIN
  SELECT NULLIF(trim(email),''), vendor_name INTO v_email, v_name
  FROM qvm_new_apps.vendors WHERE vendor_id = p_vendor_id;

  IF v_email IS NULL THEN
    RETURN NULL; -- can't create a login without an email
  END IF;

  IF EXISTS (SELECT 1 FROM qvm_new_apps.user_data WHERE user_type = 205 AND user_vendor = p_vendor_id) THEN
    RETURN NULL; -- vendor already has a login
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(v_email)) THEN
    RETURN NULL; -- email already used by an auth account; don't collide
  END IF;

  SELECT ld.list_data_id INTO v_role
  FROM qvm_new_apps.list_data ld
  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
  WHERE l.list_name = 'user_role' AND ld.list_data = 'Vendor Admin'
  LIMIT 1;
  IF v_role IS NULL THEN
    RETURN NULL;
  END IF;

  v_uid := gen_random_uuid();

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    lower(v_email), extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false
  );

  INSERT INTO auth.identities (
    provider_id, user_id, identity_data, provider, created_at, updated_at, email
  ) VALUES (
    v_uid::text, v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', lower(v_email), 'email_verified', true, 'phone_verified', false),
    'email', now(), now(), lower(v_email)
  );

  INSERT INTO qvm_new_apps.user_data (user_id, email, user_name, user_type, user_role, user_vendor)
  VALUES (v_uid, lower(v_email), COALESCE(v_name, v_email), 205, v_role, p_vendor_id);

  RETURN v_uid;
END;
$$;

REVOKE ALL ON FUNCTION qvm_new_apps.ensure_vendor_login(integer, text) FROM PUBLIC;

-- Auto-provision a login for every newly created vendor (covers sheet import, admin vendor page,
-- quick-add from quotation, and any other path that inserts into vendors). Never blocks the insert.
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_vendor_ensure_login()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','auth','extensions','public'
AS $$
BEGIN
  BEGIN
    PERFORM qvm_new_apps.ensure_vendor_login(NEW.vendor_id, '123456');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'ensure_vendor_login failed for vendor %: %', NEW.vendor_id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS vendors_ensure_login ON qvm_new_apps.vendors;
CREATE TRIGGER vendors_ensure_login
AFTER INSERT ON qvm_new_apps.vendors
FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.trg_vendor_ensure_login();
;
