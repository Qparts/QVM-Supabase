-- A rule teaches the vendor its brand.
--
-- The Vendor default brands tab reflects the rules: when a rule names a vendor for a car brand, that
-- brand joins the vendor's default brands. Saving or merging a rule does it; existing rules are
-- brought in line once here. Removing a rule takes nothing away — a brand learned stays learned
-- until an admin clears it on the vendor.
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_teach_vendor_brands(p_rule_id bigint)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v_n integer;
BEGIN
  INSERT INTO qvm_new_apps.vendor_default_brands (vendor_id, brand_id, created_by)
  SELECT DISTINCT rv.vendor_id, r.brand_id, auth.uid()
    FROM qvm_new_apps.auto_rfq_rule_vendors rv
    JOIN qvm_new_apps.auto_rfq_rules r ON r.rule_id = rv.rule_id
    JOIN qvm_new_apps.vendors v ON v.vendor_id = rv.vendor_id
   WHERE rv.rule_id = p_rule_id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION qvm_new_apps.auto_rfq_teach_vendor_brands(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.auto_rfq_teach_vendor_brands(bigint) TO authenticated, service_role;

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

  -- A rule teaches the vendor its brand: naming a vendor for a brand is the admin saying "this vendor
  -- quotes this brand", so it becomes one of the vendor's default brands — selected on the Vendor
  -- default brands tab, and no longer flagged as outside them.
  PERFORM qvm_new_apps.auto_rfq_teach_vendor_brands(v_id);

  RETURN jsonb_build_object('status', 'success', 'rule_id', v_id, 'merged', v_existing IS NOT NULL);
END $$;

-- The rules saved before this: every vendor learns the brand of every rule it is on.
SELECT qvm_new_apps.auto_rfq_teach_vendor_brands(r.rule_id) FROM qvm_new_apps.auto_rfq_rules r;
