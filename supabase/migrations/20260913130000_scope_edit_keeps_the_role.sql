-- Editing a user's scope must not take a Company Admin's role away.
--
-- admin_set_user_scope normalises an internal user who has companies to Internal Branch User (271),
-- which is right for the account that has no other role and wrong for the two that do. Qparts Admin
-- was already spared; Company Admin was not, so saving one's company list — or creating one, since
-- creation ends with this very call — silently demoted them to 271 and took away everything the
-- role exists for. The role id is looked up by name rather than written as a literal, because it is
-- minted per environment: 316 on dev is not 316 anywhere else.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_user_scope(p_user_id uuid, p_workshop_ids bigint[] DEFAULT NULL::bigint[], p_branches jsonb DEFAULT NULL::jsonb, p_company_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_type int;
  v_company integer;
  v_is_workshop_user boolean;
BEGIN
  -- A Company Admin may place people inside their own company: every workshop and every company
  -- named has to be one they administer, and the user they are moving must already be reachable
  -- from there — otherwise this call would be a way to adopt somebody else's account.
  IF NOT (qvm_new_apps.is_qparts_admin_or_service()
          OR (qvm_new_apps.is_company_admin(auth.uid())
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_workshop(w))
                              FROM unnest(COALESCE(p_workshop_ids, ARRAY[]::bigint[])) w), true)
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_company(c))
                              FROM unnest(COALESCE(p_company_ids, ARRAY[]::integer[])) c), true)
              AND COALESCE((SELECT bool_and(qvm_new_apps.can_admin_branch((b->>'customer_id')::int))
                              FROM jsonb_array_elements(COALESCE(p_branches, '[]'::jsonb)) b), true))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: that is outside your company');
  END IF;
  SELECT user_type INTO v_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  IF p_workshop_ids IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id
       AND NOT (workshop_id = ANY(p_workshop_ids));
    INSERT INTO qvm_new_apps.user_workshops (user_id, workshop_id, created_by)
    SELECT p_user_id, w, v_uid FROM unnest(p_workshop_ids) w
    ON CONFLICT (user_id, workshop_id) DO NOTHING;
  END IF;

  IF p_company_ids IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_companies WHERE user_id = p_user_id
       AND NOT (company_id = ANY(p_company_ids));
    INSERT INTO qvm_new_apps.user_companies (user_id, company_id, created_by)
    SELECT p_user_id, c, v_uid FROM unnest(p_company_ids) c
    ON CONFLICT (user_id, company_id) DO NOTHING;
  END IF;

  IF p_branches IS NOT NULL THEN
    DELETE FROM qvm_new_apps.user_branches ub
     WHERE ub.user_id = p_user_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_branches) b
                        WHERE (b->>'customer_id')::int = ub.client_branch_id);
    INSERT INTO qvm_new_apps.user_branches (user_id, client_branch_id, is_manager, created_by)
    SELECT p_user_id, (b->>'customer_id')::int, COALESCE((b->>'is_manager')::boolean, false), v_uid
    FROM jsonb_array_elements(p_branches) b
    ON CONFLICT (user_id, client_branch_id) DO UPDATE SET is_manager = EXCLUDED.is_manager;
  END IF;

  -- The role follows what the person now IS. It is not decoration: the sidebar and the route guard
  -- are built from user_role, so a branch manager promoted to the whole workshop and left on 195
  -- would keep a branch manager's menu.
  IF v_type = 183 THEN
    v_is_workshop_user := EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops WHERE user_id = p_user_id);
    UPDATE qvm_new_apps.user_data
    SET user_role = CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END,
        updated_at = now()
    WHERE user_id = p_user_id AND user_role <> CASE WHEN v_is_workshop_user THEN 170 ELSE 195 END;
  ELSIF v_type = 185
        AND EXISTS (SELECT 1 FROM qvm_new_apps.user_companies WHERE user_id = p_user_id) THEN
    -- An internal user scoped to companies is an Internal Branch User: the whole menu, narrowed
    -- data. Qparts Admins are left alone — their reach is the point of the role.
    UPDATE qvm_new_apps.user_data
    SET user_role = 271, updated_at = now()
    WHERE user_id = p_user_id
      AND user_role NOT IN (172, 271)
      AND user_role IS DISTINCT FROM qvm_new_apps.company_admin_role_id();
  END IF;

  SELECT COALESCE(
    (SELECT w.company_id FROM qvm_new_apps.user_workshops uw
       JOIN qvm_new_apps.client_workshops w ON w.workshop_id = uw.workshop_id
      WHERE uw.user_id = p_user_id LIMIT 1),
    (SELECT uc.company_id FROM qvm_new_apps.user_companies uc WHERE uc.user_id = p_user_id LIMIT 1))
  INTO v_company;

  UPDATE qvm_new_apps.user_data ud
  SET user_company = COALESCE(v_company, ud.user_company),
      user_branch  = COALESCE((SELECT ub.client_branch_id FROM qvm_new_apps.user_branches ub
                                WHERE ub.user_id = p_user_id ORDER BY ub.is_manager DESC LIMIT 1),
                              (SELECT cb.customer_id FROM qvm_new_apps.user_workshops uw
                                 JOIN qvm_new_apps.client_branches cb ON cb.workshop_id = uw.workshop_id
                                WHERE uw.user_id = p_user_id LIMIT 1),
                              ud.user_branch),
      updated_at = now()
  WHERE ud.user_id = p_user_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'user_id', p_user_id,
    'user_role', (SELECT user_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id),
    'branch_ids', to_jsonb(qvm_new_apps.effective_branch_ids(p_user_id))));
END $function$;
