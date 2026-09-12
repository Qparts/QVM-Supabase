-- The branch provisions itself, and the tree shows a workshop under every company it serves.
--
-- A workshop with three companies appears three times in the tree, once under each — it is the same
-- workshop, and the admin reaches it from whichever company they were looking at. "Unassigned" now
-- means no companies at all rather than a null column.
--
-- Each branch also carries its own readiness: an order is raised ON A BRANCH, so that is where the
-- reasons it would be refused belong.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_upsert_branch(p_workshop_id bigint, p_names jsonb, p_customer_id integer DEFAULT NULL::integer, p_city_id integer DEFAULT NULL::integer, p_location_lat double precision DEFAULT NULL::double precision, p_location_lng double precision DEFAULT NULL::double precision, p_is_bulk_client boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_company integer; v_id integer; v_default_name text; v_city_name text;
  v_lat double precision; v_lng double precision;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  -- The primary company only. A branch serves every company its workshop does; list_data_id is the
  -- one the older dashboards group by, not a statement about who the work is for.
  SELECT w.company_id INTO v_company FROM qvm_new_apps.client_workshops w WHERE w.workshop_id = p_workshop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  IF p_city_id IS NOT NULL THEN
    SELECT c.name, c.location_lat, c.location_lng INTO v_city_name, v_lat, v_lng
    FROM qvm_new_apps.v_cities c WHERE c.city_id = p_city_id;
    IF v_city_name IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'City not found');
    END IF;
  END IF;

  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF p_customer_id IS NULL THEN
    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city_id, city, location_lat, location_lng, is_bulk_client)
    -- The city's own coordinates are the starting point; a branch keeps its own once given one.
    VALUES (v_company, p_workshop_id, v_default_name, p_city_id, v_city_name,
            COALESCE(p_location_lat, v_lat), COALESCE(p_location_lng, v_lng),
            COALESCE(p_is_bulk_client, false))
    RETURNING customer_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.client_branches
    SET workshop_id = p_workshop_id, list_data_id = v_company, branch_name = v_default_name,
        city_id = COALESCE(p_city_id, city_id),
        city    = COALESCE(v_city_name, city),
        location_lat = COALESCE(p_location_lat, location_lat, v_lat),
        location_lng = COALESCE(p_location_lng, location_lng, v_lng),
        is_bulk_client = COALESCE(p_is_bulk_client, is_bulk_client),
        updated_at = now()
    WHERE customer_id = p_customer_id
    RETURNING customer_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
    END IF;
  END IF;

  INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (customer_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  DELETE FROM qvm_new_apps.client_branches_descriptions d
   WHERE d.customer_id = v_id
     AND d.language_id <> qvm_new_apps.default_language_id()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = d.language_id
                        AND btrim(COALESCE(n->>'name', '')) <> '');

  -- Region, order-number sequences and an account manager, so the branch can take an order the
  -- moment it exists rather than failing at the first RFQ with a message that names none of this.
  PERFORM qvm_new_apps.provision_branch_for_quotations(v_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', v_id,
    'readiness', qvm_new_apps.branch_quotation_readiness(v_id)));
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  WITH workshop_json AS (
    SELECT w.workshop_id, w.company_id,
           jsonb_build_object(
             'workshop_id', w.workshop_id,
             'company_id', w.company_id,
             'company_ids', COALESCE((SELECT jsonb_agg(wc.company_id ORDER BY wc.company_id)
                                        FROM qvm_new_apps.workshop_companies wc
                                       WHERE wc.workshop_id = w.workshop_id), '[]'::jsonb),
             'display_name', vw.name,
             'city', w.city,
             'city_id', w.city_id,
             'is_active', w.is_active,
             'branch_count', vw.branch_count,
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.client_workshops_descriptions d
                                 WHERE d.workshop_id = w.workshop_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'customer_id', b.customer_id,
                        'display_name', vb.name,
                        'city', b.city,
                        'city_id', b.city_id,
                        'is_bulk_client', b.is_bulk_client,
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                            ORDER BY d.language_id)
                                             FROM qvm_new_apps.client_branches_descriptions d
                                            WHERE d.customer_id = b.customer_id), '[]'::jsonb),
                        'manager_count', (SELECT count(*) FROM qvm_new_apps.user_branches ub
                                           WHERE ub.client_branch_id = b.customer_id AND ub.is_manager),
                        -- Shown per branch because that is where it fails: an order is raised on a
                        -- branch, and this is the list of reasons it would be refused.
                        'readiness', qvm_new_apps.branch_quotation_readiness(b.customer_id))
                      ORDER BY vb.name)
                 FROM qvm_new_apps.client_branches b
                 JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = b.customer_id
                WHERE b.workshop_id = w.workshop_id), '[]'::jsonb),
             'user_count', (SELECT count(*) FROM qvm_new_apps.user_workshops uw WHERE uw.workshop_id = w.workshop_id)
           ) AS ws
    FROM qvm_new_apps.client_workshops w
    JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
  )
  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                               FROM (SELECT language_id, code, english_name, native_name, direction,
                                            is_active, is_default, sort_order
                                       FROM qvm_new_apps.languages WHERE is_active) l), '[]'::jsonb),
      'unassigned_workshops', COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                                          FROM workshop_json wj
                                         WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies wc
                                                            WHERE wc.workshop_id = wj.workshop_id)), '[]'::jsonb),
      'companies', COALESCE((
        SELECT jsonb_agg(co ORDER BY co->>'display_name')
        FROM (
          SELECT jsonb_build_object(
            'company_id', c.company_id,
            'display_name', vc.name,
            'cr_number', c.cr_number,
            'vat_number', c.vat_number,
            'is_active', c.is_active,
            'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                ORDER BY d.language_id)
                                 FROM qvm_new_apps.client_companies_descriptions d
                                WHERE d.company_id = c.company_id), '[]'::jsonb),
            'workshops', COALESCE((SELECT jsonb_agg(wj.ws ORDER BY wj.ws->>'display_name')
                                     FROM workshop_json wj
                                     JOIN qvm_new_apps.workshop_companies wc
                                       ON wc.workshop_id = wj.workshop_id
                                    WHERE wc.company_id = c.company_id), '[]'::jsonb)
          ) AS co
          FROM qvm_new_apps.client_companies c
          JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = c.company_id
        ) s), '[]'::jsonb)
    ))
  INTO v_res;

  RETURN v_res;
END $function$;
