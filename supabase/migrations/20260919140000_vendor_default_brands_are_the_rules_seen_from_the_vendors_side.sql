-- Vendor default brands are the rules, seen from the vendor's side.
--
-- Not a copy of the vendors' own brand columns: the tab lists every vendor with the brands the
-- rules assign it, per client branch and vendor branch. Ticking a brand for a vendor under a client
-- branch puts that vendor (with the vendor branch chosen) on the rule for that client branch and
-- brand — creating the rule if there is none — and unticking takes it off, removing a rule left
-- with no vendors. The rules are the single source of truth; the separate table and its seed go.

DROP FUNCTION IF EXISTS public.set_vendor_default_brands(integer, integer[]);
DROP FUNCTION IF EXISTS qvm_new_apps.set_vendor_default_brands(integer, integer[]);
DROP FUNCTION IF EXISTS public.list_vendor_default_brands();
DROP FUNCTION IF EXISTS qvm_new_apps.list_vendor_default_brands();
DROP FUNCTION IF EXISTS qvm_new_apps.auto_rfq_teach_vendor_brands(bigint);
DROP TABLE IF EXISTS qvm_new_apps.vendor_default_brands;

CREATE OR REPLACE FUNCTION qvm_new_apps.save_auto_rfq_rule(
  p_rule_id bigint, p_customer_id integer, p_brand_id integer, p_vendors jsonb, p_statuses integer[], p_merge boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_existing bigint;
  v_id       bigint := p_rule_id;
  v_statuses integer[] := (SELECT array_agg(DISTINCT s ORDER BY s) FROM unnest(COALESCE(p_statuses, ARRAY[]::integer[])) s WHERE s IN (235, 236));
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  IF p_customer_id IS NULL OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = p_customer_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick a branch');
  END IF;
  IF p_brand_id IS NULL OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = p_brand_id AND ld.list_id = 4) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick a car brand');
  END IF;
  IF p_vendors IS NULL OR jsonb_typeof(p_vendors) <> 'array' OR jsonb_array_length(p_vendors) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick at least one vendor');
  END IF;
  IF v_statuses IS NULL OR cardinality(v_statuses) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick at least one status');
  END IF;

  SELECT r.rule_id INTO v_existing FROM qvm_new_apps.auto_rfq_rules r
   WHERE r.customer_id = p_customer_id AND r.brand_id = p_brand_id
     AND (p_rule_id IS NULL OR r.rule_id <> p_rule_id);
  IF v_existing IS NOT NULL AND NOT COALESCE(p_merge, false) THEN
    RETURN jsonb_build_object('status', 'conflict', 'rule_id', v_existing,
      'message', 'A rule for this branch and brand already exists');
  END IF;

  IF v_existing IS NOT NULL THEN
    -- Merge into the existing rule: union of vendors and statuses; the draft (or the edited rule) folds away.
    UPDATE qvm_new_apps.auto_rfq_rules
       SET trigger_statuses = (SELECT array_agg(DISTINCT s ORDER BY s) FROM unnest(trigger_statuses || v_statuses) s),
           updated_by = v_uid, updated_at = now()
     WHERE rule_id = v_existing;
    IF p_rule_id IS NOT NULL THEN
      INSERT INTO qvm_new_apps.auto_rfq_rule_vendors (rule_id, vendor_id, vendor_branch_id)
      SELECT v_existing, rv.vendor_id, rv.vendor_branch_id FROM qvm_new_apps.auto_rfq_rule_vendors rv WHERE rv.rule_id = p_rule_id
      ON CONFLICT DO NOTHING;
      DELETE FROM qvm_new_apps.auto_rfq_rules WHERE rule_id = p_rule_id;
    END IF;
    v_id := v_existing;
  ELSIF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.auto_rfq_rules (customer_id, brand_id, trigger_statuses, created_by, updated_by)
    VALUES (p_customer_id, p_brand_id, v_statuses, v_uid, v_uid)
    RETURNING rule_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.auto_rfq_rules
       SET customer_id = p_customer_id, brand_id = p_brand_id, trigger_statuses = v_statuses,
           updated_by = v_uid, updated_at = now()
     WHERE rule_id = v_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'error', 'message', 'That rule no longer exists'); END IF;
    -- An edit replaces the vendor set.
    DELETE FROM qvm_new_apps.auto_rfq_rule_vendors WHERE rule_id = v_id;
  END IF;

  INSERT INTO qvm_new_apps.auto_rfq_rule_vendors (rule_id, vendor_id, vendor_branch_id)
  SELECT v_id, (x->>'vendor_id')::integer, NULLIF(x->>'vendor_branch_id', '')::bigint
    FROM jsonb_array_elements(p_vendors) x
   WHERE NULLIF(x->>'vendor_id', '') IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', 'success', 'rule_id', v_id, 'merged', v_existing IS NOT NULL);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_auto_rfq_options()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN jsonb_build_object(
    'branches', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('customer_id', cb.customer_id, 'name', cb.branch_name,
                                          'company_name', cn.list_data, 'city', cb.city)
                       ORDER BY cn.list_data NULLS LAST, cb.branch_name)
        FROM qvm_new_apps.client_branches cb
        LEFT JOIN qvm_new_apps.list_data cn ON cn.list_data_id = cb.list_data_id), '[]'::jsonb),
    'brands', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('brand_id', ld.list_data_id, 'name', ld.list_data) ORDER BY ld.list_data)
        FROM qvm_new_apps.list_data ld WHERE ld.list_id = 4), '[]'::jsonb),
    'vendors', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'vendor_id', v.vendor_id, 'vendor_name', v.vendor_name,
               -- The brands this vendor is assigned on any rule, for any client branch.
               'assigned_brand_ids', COALESCE((SELECT jsonb_agg(DISTINCT r.brand_id)
                                                 FROM qvm_new_apps.auto_rfq_rule_vendors rv
                                                 JOIN qvm_new_apps.auto_rfq_rules r ON r.rule_id = rv.rule_id
                                                WHERE rv.vendor_id = v.vendor_id), '[]'::jsonb),
               'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object('vendor_branch_id', vbr.vendor_branch_id,
                                                                          'branch_name', vbr.branch_name, 'city', vbr.city)
                                                     ORDER BY vbr.branch_name)
                                       FROM qvm_new_apps.vendor_branches vbr
                                      WHERE vbr.vendor_id = v.vendor_id AND vbr.is_active), '[]'::jsonb))
               ORDER BY v.vendor_name)
        FROM qvm_new_apps.vendors v
       WHERE COALESCE(v.receives_quotations, true)), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_auto_rfq_rules()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN jsonb_build_object(
    'active_count', (SELECT count(*) FROM qvm_new_apps.auto_rfq_rules r WHERE r.is_active),
    'rules', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'rule_id', r.rule_id,
               'customer_id', r.customer_id,
               'branch_name', cb.branch_name,
               'company_name', cn.list_data,
               'brand_id', r.brand_id,
               'brand_name', br.list_data,
               'trigger_statuses', to_jsonb(r.trigger_statuses),
               'is_active', r.is_active,
               'created_at', r.created_at,
               'updated_at', r.updated_at,
               'sends_count', (SELECT count(*) FROM qvm_new_apps.auto_rfq_sends s WHERE s.rule_id = r.rule_id AND s.status = 'sent'),
               'last_sent_at', (SELECT max(s.sent_at) FROM qvm_new_apps.auto_rfq_sends s WHERE s.rule_id = r.rule_id),
               'vendors', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'vendor_id', rv.vendor_id,
                          'vendor_branch_id', rv.vendor_branch_id,
                          'vendor_name', v.vendor_name,
                          'branch_name', vbr.branch_name,
                          -- The vendor is gone, or the branch is: shown as unavailable, not dropped.
                          'missing', v.vendor_id IS NULL OR (rv.vendor_branch_id IS NOT NULL AND vbr.vendor_branch_id IS NULL),
                          -- The same vendor on the same brand for other client branches: context, not a warning.
                          'other_branches', (SELECT count(DISTINCT r2.customer_id)
                                               FROM qvm_new_apps.auto_rfq_rule_vendors rv2
                                               JOIN qvm_new_apps.auto_rfq_rules r2 ON r2.rule_id = rv2.rule_id
                                              WHERE rv2.vendor_id = rv.vendor_id AND r2.brand_id = r.brand_id AND r2.rule_id <> r.rule_id))
                        ORDER BY v.vendor_name NULLS LAST)
                   FROM qvm_new_apps.auto_rfq_rule_vendors rv
                   LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = rv.vendor_id
                   LEFT JOIN qvm_new_apps.vendor_branches vbr ON vbr.vendor_branch_id = rv.vendor_branch_id
                  WHERE rv.rule_id = r.rule_id), '[]'::jsonb))
             ORDER BY cn.list_data NULLS LAST, cb.branch_name, br.list_data)
        FROM qvm_new_apps.auto_rfq_rules r
        LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = r.customer_id
        LEFT JOIN qvm_new_apps.list_data cn ON cn.list_data_id = cb.list_data_id
        LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = r.brand_id), '[]'::jsonb));
END $$;

-- The vendor-side view. With a client branch: each vendor's assignments there, and the vendor branch
-- they were made with. Without one: an overview — how many client branches each vendor × brand covers.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_default_brands(p_customer_id integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN jsonb_build_object(
    'customer_id', p_customer_id,
    'branches', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('customer_id', cb.customer_id, 'name', cb.branch_name,
                                          'company_name', cn.list_data, 'city', cb.city,
                                          'rules_count', (SELECT count(*) FROM qvm_new_apps.auto_rfq_rules r WHERE r.customer_id = cb.customer_id))
                       ORDER BY cn.list_data NULLS LAST, cb.branch_name)
        FROM qvm_new_apps.client_branches cb
        LEFT JOIN qvm_new_apps.list_data cn ON cn.list_data_id = cb.list_data_id), '[]'::jsonb),
    'brands', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('brand_id', ld.list_data_id, 'name', ld.list_data) ORDER BY ld.list_data)
        FROM qvm_new_apps.list_data ld WHERE ld.list_id = 4), '[]'::jsonb),
    'vendors', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'vendor_id', v.vendor_id, 'vendor_name', v.vendor_name,
               'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object('vendor_branch_id', vbr.vendor_branch_id,
                                                                          'branch_name', vbr.branch_name, 'city', vbr.city)
                                                     ORDER BY vbr.branch_name)
                                       FROM qvm_new_apps.vendor_branches vbr
                                      WHERE vbr.vendor_id = v.vendor_id AND vbr.is_active), '[]'::jsonb),
               -- For one client branch: the brands assigned there, with the vendor branch used.
               'assignments', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object('brand_id', r.brand_id, 'vendor_branch_id', rv.vendor_branch_id,
                                                     'rule_id', r.rule_id, 'is_active', r.is_active) ORDER BY r.brand_id)
                   FROM qvm_new_apps.auto_rfq_rule_vendors rv
                   JOIN qvm_new_apps.auto_rfq_rules r ON r.rule_id = rv.rule_id
                  WHERE rv.vendor_id = v.vendor_id AND (p_customer_id IS NULL OR r.customer_id = p_customer_id)), '[]'::jsonb),
               -- Across all client branches: how many branches each brand is assigned for.
               'coverage', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object('brand_id', x.brand_id, 'branches', x.n) ORDER BY x.brand_id)
                   FROM (SELECT r.brand_id, count(DISTINCT r.customer_id) AS n
                           FROM qvm_new_apps.auto_rfq_rule_vendors rv
                           JOIN qvm_new_apps.auto_rfq_rules r ON r.rule_id = rv.rule_id
                          WHERE rv.vendor_id = v.vendor_id GROUP BY r.brand_id) x), '[]'::jsonb))
               ORDER BY v.vendor_name)
        FROM qvm_new_apps.vendors v
       WHERE COALESCE(v.receives_quotations, true)), '[]'::jsonb));
END $$;

-- The write: the whole brand set of one vendor for one client branch, with the vendor branch chosen.
-- A brand added joins (or creates) the rule for that client branch and brand; a brand removed leaves
-- it, and a rule left with no vendors is deleted. A rule created here sends at Ready For Quotation
-- and is active — the Rules tab is where that is changed.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_brands_for_branch(
  p_customer_id integer, p_vendor_id integer, p_vendor_branch_id bigint, p_brand_ids integer[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_brand integer;
  v_rule  bigint;
  v_added integer := 0;
  v_removed integer := 0;
  v_wanted integer[] := COALESCE(p_brand_ids, ARRAY[]::integer[]);
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  IF p_customer_id IS NULL OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = p_customer_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick a client branch');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_vendor_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unknown vendor');
  END IF;
  IF p_vendor_branch_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.vendor_branches b WHERE b.vendor_branch_id = p_vendor_branch_id AND b.vendor_id = p_vendor_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'That branch does not belong to this vendor');
  END IF;
  IF p_vendor_branch_id IS NULL AND EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branches b WHERE b.vendor_id = p_vendor_id AND b.is_active) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Pick the vendor branch');
  END IF;

  -- Brands to add (or whose vendor branch changes).
  FOREACH v_brand IN ARRAY v_wanted LOOP
    IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = v_brand AND ld.list_id = 4) THEN CONTINUE; END IF;
    SELECT r.rule_id INTO v_rule FROM qvm_new_apps.auto_rfq_rules r WHERE r.customer_id = p_customer_id AND r.brand_id = v_brand;
    IF v_rule IS NULL THEN
      INSERT INTO qvm_new_apps.auto_rfq_rules (customer_id, brand_id, trigger_statuses, is_active, created_by, updated_by)
      VALUES (p_customer_id, v_brand, ARRAY[235], true, v_uid, v_uid) RETURNING rule_id INTO v_rule;
    END IF;
    -- One row per vendor on a rule: the chosen vendor branch replaces an earlier one.
    DELETE FROM qvm_new_apps.auto_rfq_rule_vendors rv
     WHERE rv.rule_id = v_rule AND rv.vendor_id = p_vendor_id AND rv.vendor_branch_id IS DISTINCT FROM p_vendor_branch_id;
    INSERT INTO qvm_new_apps.auto_rfq_rule_vendors (rule_id, vendor_id, vendor_branch_id)
    VALUES (v_rule, p_vendor_id, p_vendor_branch_id)
    ON CONFLICT DO NOTHING;
    IF FOUND THEN v_added := v_added + 1; END IF;
    UPDATE qvm_new_apps.auto_rfq_rules SET updated_by = v_uid, updated_at = now() WHERE rule_id = v_rule;
  END LOOP;

  -- Brands to remove: the vendor leaves those rules; a rule with nobody left goes.
  WITH gone AS (
    DELETE FROM qvm_new_apps.auto_rfq_rule_vendors rv
     USING qvm_new_apps.auto_rfq_rules r
     WHERE r.rule_id = rv.rule_id AND r.customer_id = p_customer_id AND rv.vendor_id = p_vendor_id
       AND NOT (r.brand_id = ANY(v_wanted))
    RETURNING r.rule_id)
  SELECT count(*) INTO v_removed FROM gone;
  DELETE FROM qvm_new_apps.auto_rfq_rules r
   WHERE r.customer_id = p_customer_id
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.auto_rfq_rule_vendors rv WHERE rv.rule_id = r.rule_id);

  RETURN jsonb_build_object('status', 'success', 'added', v_added, 'removed', v_removed);
END $$;

CREATE OR REPLACE FUNCTION public.list_vendor_default_brands(p_customer_id integer DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_vendor_default_brands(p_customer_id) $$;
CREATE OR REPLACE FUNCTION public.set_vendor_brands_for_branch(p_customer_id integer, p_vendor_id integer, p_vendor_branch_id bigint, p_brand_ids integer[]) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.set_vendor_brands_for_branch(p_customer_id, p_vendor_id, p_vendor_branch_id, p_brand_ids) $$;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.list_vendor_default_brands(integer)', 'qvm_new_apps.list_vendor_default_brands(integer)',
                           'public.set_vendor_brands_for_branch(integer, integer, bigint, integer[])',
                           'qvm_new_apps.set_vendor_brands_for_branch(integer, integer, bigint, integer[])']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;
