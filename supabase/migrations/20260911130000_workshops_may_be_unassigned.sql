-- A workshop may stand without a company until the admin assigns it.
--
-- Workshops arrive before the paperwork does: someone registers the site, its branches and its
-- people, and only later is it settled which company it trades under. Forcing a company at creation
-- meant inventing one, and an invented company is worse than an empty field — it ends up on orders.
--
-- What does NOT change: a workshop still cannot exist without branches, and once a company IS set,
-- every branch under that workshop belongs to it. The composite foreign key
-- (workshop_id, list_data_id) → (workshop_id, company_id) keeps that true, and because it is
-- MATCH SIMPLE it stands aside while either side is NULL — unchecked while unassigned, enforced the
-- moment a company is named. That is the behaviour we want and it is worth saying out loud, because
-- it looks like a hole until you know the assignment cascades the company down to the branches in
-- the same transaction.

ALTER TABLE qvm_new_apps.client_workshops              ALTER COLUMN company_id DROP NOT NULL;
ALTER TABLE qvm_new_apps.client_workshops_descriptions ALTER COLUMN company_id DROP NOT NULL;

-- The composite key has to be DEFERRED to survive an assignment.
--
-- Assigning a workshop moves two rows that reference each other: the workshop's company, and its
-- branches' company. Checked immediately, NEITHER order is legal — set the branches first and they
-- point at a company their workshop does not yet have; set the workshop first and the branches are
-- left pointing at one it no longer has. Deferring the check to COMMIT lets the transaction pass
-- through that inconsistent middle and be judged on where it ends up, which is the only state that
-- was ever meant to be true.
ALTER TABLE qvm_new_apps.client_branches
  DROP CONSTRAINT IF EXISTS client_branches_workshop_company_fk;
ALTER TABLE qvm_new_apps.client_branches
  ADD CONSTRAINT client_branches_workshop_company_fk
  FOREIGN KEY (workshop_id, list_data_id)
  REFERENCES qvm_new_apps.client_workshops (workshop_id, company_id)
  DEFERRABLE INITIALLY DEFERRED;

-- The workshop's own name rows hold the same composite key, for the same reason and with the same
-- problem: changing a workshop's company leaves its descriptions pointing at the old pair for the
-- rest of the statement. Deferred as well, so the assignment is judged once, whole.
ALTER TABLE qvm_new_apps.client_workshops_descriptions
  DROP CONSTRAINT IF EXISTS client_workshops_descriptions_workshop_id_company_id_fkey;
ALTER TABLE qvm_new_apps.client_workshops_descriptions
  ADD CONSTRAINT client_workshops_descriptions_workshop_id_company_id_fkey
  FOREIGN KEY (workshop_id, company_id)
  REFERENCES qvm_new_apps.client_workshops (workshop_id, company_id) ON DELETE CASCADE
  DEFERRABLE INITIALLY DEFERRED;

-- Unassigned workshops are a staging area, so their names are not held unique against each other:
-- the unique index below is scoped to a company, and NULLs are distinct in Postgres. Two workshops
-- named "Riyadh Collision" can wait side by side; they collide only if assigned to the same company.
COMMENT ON COLUMN qvm_new_apps.client_workshops.company_id IS
  'The company this workshop trades under. NULL until a Qparts Admin assigns it.';

------------------------------------------------------------------------------ create, unassigned

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_create_workshop(
  p_company_id integer,
  p_names      jsonb,
  p_branches   jsonb,
  p_city       text DEFAULT NULL,
  p_region_id  integer DEFAULT NULL,
  p_location_lat double precision DEFAULT NULL,
  p_location_lng double precision DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ws bigint;
  v_branch integer;
  b jsonb;
  v_ids integer[] := ARRAY[]::integer[];
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  -- NULL is allowed and means "not assigned yet"; a company that is named must exist.
  IF p_company_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Company not found');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);
  IF p_branches IS NULL OR jsonb_typeof(p_branches) <> 'array' OR jsonb_array_length(p_branches) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'A workshop must be created with at least one branch');
  END IF;
  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    PERFORM qvm_new_apps.assert_names_valid(b->'names');
  END LOOP;

  INSERT INTO qvm_new_apps.client_workshops (company_id, city, region_id, location_lat, location_lng, created_by, updated_by)
  VALUES (p_company_id, p_city, p_region_id, p_location_lat, p_location_lng, v_uid, v_uid)
  RETURNING workshop_id INTO v_ws;

  INSERT INTO qvm_new_apps.client_workshops_descriptions (workshop_id, company_id, language_id, name, created_by, updated_by)
  SELECT v_ws, p_company_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> '';

  FOR b IN SELECT * FROM jsonb_array_elements(p_branches) LOOP
    INSERT INTO qvm_new_apps.client_branches
      (list_data_id, workshop_id, branch_name, city, region_id, location_lat, location_lng, is_bulk_client)
    VALUES (p_company_id, v_ws,
            (SELECT btrim(n->>'name') FROM jsonb_array_elements(b->'names') n
              WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1),
            COALESCE(b->>'city', p_city),
            COALESCE((b->>'region_id')::int, p_region_id),
            COALESCE((b->>'location_lat')::double precision, p_location_lat),
            COALESCE((b->>'location_lng')::double precision, p_location_lng),
            COALESCE((b->>'is_bulk_client')::boolean, false))
    RETURNING customer_id INTO v_branch;

    INSERT INTO qvm_new_apps.client_branches_descriptions (customer_id, language_id, name, created_by, updated_by)
    SELECT v_branch, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
    FROM jsonb_array_elements(b->'names') n
    WHERE btrim(COALESCE(n->>'name', '')) <> '';

    v_ids := v_ids || v_branch;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', v_ws,
    'branch_ids', to_jsonb(v_ids),
    'company_id', p_company_id,
    'unassigned', p_company_id IS NULL));
END $$;

------------------------------------------------------------------------------ assign

-- Assigning a workshop to a company moves its branches with it, in one transaction. Doing it in two
-- steps would leave branches pointing at one company while their workshop trades under another —
-- which the composite foreign key would refuse anyway, but only after the first half had been
-- written. Passing NULL detaches the workshop again.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_assign_workshop_company(
  p_workshop_id bigint,
  p_company_id  integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_current integer;
  v_branches integer;
  v_orders integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;

  SELECT company_id INTO v_current FROM qvm_new_apps.client_workshops WHERE workshop_id = p_workshop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Workshop not found');
  END IF;
  IF p_company_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_companies WHERE company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Company not found');
  END IF;

  -- Detaching a workshop whose branches already carry orders would strand those orders outside
  -- every company-scoped dashboard. Moving between companies is fine; going back to nothing is not.
  IF p_company_id IS NULL AND v_current IS NOT NULL THEN
    SELECT count(*) INTO v_orders
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    WHERE cb.workshop_id = p_workshop_id;
    IF v_orders > 0 THEN
      RETURN jsonb_build_object('success', false, 'error',
        format('This workshop already has %s order line(s) against its branches and cannot be left without a company. Assign it to another company instead.', v_orders));
    END IF;
  END IF;

  -- Branches first: while the workshop still carries the old company, both sides of the composite
  -- key agree at every step. Deferred constraints would allow either order; this one needs no help.
  UPDATE qvm_new_apps.client_branches
  SET list_data_id = p_company_id, updated_at = now()
  WHERE workshop_id = p_workshop_id;
  GET DIAGNOSTICS v_branches = ROW_COUNT;

  UPDATE qvm_new_apps.client_workshops
  SET company_id = p_company_id, updated_by = v_uid, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  UPDATE qvm_new_apps.client_workshops_descriptions
  SET company_id = p_company_id, updated_by = v_uid, updated_at = now()
  WHERE workshop_id = p_workshop_id;

  -- The workshop's users follow it: user_data.user_company is what several screens read directly.
  UPDATE qvm_new_apps.user_data ud
  SET user_company = p_company_id, updated_at = now()
  WHERE p_company_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM qvm_new_apps.user_workshops uw
                 WHERE uw.user_id = ud.user_id AND uw.workshop_id = p_workshop_id);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', p_workshop_id,
    'company_id', p_company_id,
    'previous_company_id', v_current,
    'branches_moved', v_branches));
END $$;

------------------------------------------------------------------------------ the tree

-- Unassigned workshops belong to no company, so they cannot be nested under one. They come back in
-- their own list rather than being left out — a workshop nobody can see is a workshop nobody
-- assigns.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_client_tree()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
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
             'display_name', vw.name,
             'city', w.city,
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
                        'is_bulk_client', b.is_bulk_client,
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                            ORDER BY d.language_id)
                                             FROM qvm_new_apps.client_branches_descriptions d
                                            WHERE d.customer_id = b.customer_id), '[]'::jsonb),
                        'manager_count', (SELECT count(*) FROM qvm_new_apps.user_branches ub
                                           WHERE ub.client_branch_id = b.customer_id AND ub.is_manager))
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
                                          FROM workshop_json wj WHERE wj.company_id IS NULL), '[]'::jsonb),
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
                                     FROM workshop_json wj WHERE wj.company_id = c.company_id), '[]'::jsonb)
          ) AS co
          FROM qvm_new_apps.client_companies c
          JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = c.company_id
        ) s), '[]'::jsonb)
    ))
  INTO v_res;

  RETURN v_res;
END $$;

------------------------------------------------------------------------------ wrappers

CREATE OR REPLACE FUNCTION public.admin_assign_workshop_company(
  p_workshop_id bigint, p_company_id integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
  SELECT qvm_new_apps.admin_assign_workshop_company(p_workshop_id, p_company_id); $$;

GRANT EXECUTE ON FUNCTION public.admin_assign_workshop_company(bigint, integer) TO authenticated;
