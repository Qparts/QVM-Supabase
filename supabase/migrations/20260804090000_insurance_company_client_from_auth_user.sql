-- QNEW-86 follow-up: the Insurance Companies modal made the caller manually pick a client from a
-- global dropdown. Instead, derive client_id server-side from the authenticated user's own
-- qvm_new_apps.user_data.user_company — the same column already used elsewhere to tie a user to
-- their client (mirrors user_vendor for vendor-side users). This removes the manual select and
-- makes it impossible to create an insurance company under the wrong client by mistake.

DROP FUNCTION IF EXISTS qvm_new_apps.create_insurance_company(integer, text);

CREATE FUNCTION qvm_new_apps.create_insurance_company(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
  v_client_id integer;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Name is required');
  END IF;

  SELECT user_company INTO v_client_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  IF v_client_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client — contact an administrator');
  END IF;

  INSERT INTO qvm_new_apps.insurance_companies (client_id, name)
  VALUES (v_client_id, btrim(p_name))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status', 'success', 'id', v_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.create_insurance_company(text) TO authenticated;

DROP FUNCTION IF EXISTS qvm_new_apps.update_insurance_company(bigint, integer, text);

CREATE FUNCTION qvm_new_apps.update_insurance_company(p_id bigint, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Name is required');
  END IF;

  -- client_id is fixed at creation time from the creator's own company and is never reassigned.
  UPDATE qvm_new_apps.insurance_companies
  SET name = btrim(p_name), updated_at = now()
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Insurance company not found');
  END IF;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.update_insurance_company(bigint, text) TO authenticated;
