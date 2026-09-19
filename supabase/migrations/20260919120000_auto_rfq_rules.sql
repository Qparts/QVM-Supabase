-- Auto-RFQ: a rule pairs a branch with a car brand and a set of vendors, and fires the RFQ when
-- a line reaches the chosen status.
--
-- ARFQ-1..7. Rules are read only at fire time — editing or deleting one never touches an RFQ
-- already sent. A vendor's default brands (a keyed table, not the free-text vendors.brands the
-- dashboard filters on) say which rules the vendor is a natural fit for; a rule may still name a
-- vendor outside them, flagged. Every automatic send is a row: the unique index on
-- (line, vendor) is what guarantees one RFQ per vendor however many rules match.
--
-- Firing: a trigger on quotation_items enqueues the matching (line, vendor) pairs and pokes the
-- auto_rfq_dispatch edge function through pg_net with a shared secret held in Vault. The function
-- waits a short while so a multi-line order sends one RFQ, claims the queued rows atomically, and
-- sends through send_rfq_webhook — the same path, payload, webhook / Gmail fallback and
-- webhook_logs as a manual send.

------------------------------------------------------------------------------ tables
CREATE TABLE IF NOT EXISTS qvm_new_apps.vendor_default_brands (
  vendor_id  integer NOT NULL REFERENCES qvm_new_apps.vendors(vendor_id) ON DELETE CASCADE,
  brand_id   integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vendor_id, brand_id)
);

CREATE TABLE IF NOT EXISTS qvm_new_apps.auto_rfq_rules (
  rule_id          bigserial PRIMARY KEY,
  -- The branch: client_branches.customer_id, the same id quotation_items.customer_id carries.
  customer_id      integer NOT NULL,
  -- The car brand: list_data list 4, the same id quotation_items.main_brand carries.
  brand_id         integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  -- Extract PN (236), Ready For Quotation (235), or both.
  trigger_statuses integer[] NOT NULL,
  is_active        boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT auto_rfq_rules_statuses CHECK (cardinality(trigger_statuses) >= 1 AND trigger_statuses <@ ARRAY[235, 236]),
  CONSTRAINT auto_rfq_rules_one_per_branch_brand UNIQUE (customer_id, brand_id)
);

CREATE TABLE IF NOT EXISTS qvm_new_apps.auto_rfq_rule_vendors (
  rule_id          bigint  NOT NULL REFERENCES qvm_new_apps.auto_rfq_rules(rule_id) ON DELETE CASCADE,
  -- Not cascaded from vendors: a deleted vendor stays on the rule and shows as unavailable.
  vendor_id        integer NOT NULL,
  vendor_branch_id bigint
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_auto_rfq_rule_vendors
  ON qvm_new_apps.auto_rfq_rule_vendors (rule_id, vendor_id, COALESCE(vendor_branch_id, 0));

CREATE TABLE IF NOT EXISTS qvm_new_apps.auto_rfq_sends (
  send_id           bigserial PRIMARY KEY,
  rule_id           bigint REFERENCES qvm_new_apps.auto_rfq_rules(rule_id) ON DELETE SET NULL,
  quotation_id      bigint  NOT NULL,
  quotation_item_id bigint  NOT NULL,
  vendor_id         integer NOT NULL,
  vendor_branch_id  bigint,
  trigger_status    integer NOT NULL,
  status            text    NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'skipped', 'failed')),
  webhook_log_id    bigint,
  error             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  sent_at           timestamptz
);
-- One RFQ per vendor per line, ever — the duplicate guard for overlapping rules and repeated statuses.
CREATE UNIQUE INDEX IF NOT EXISTS uq_auto_rfq_sends_line_vendor
  ON qvm_new_apps.auto_rfq_sends (quotation_item_id, vendor_id, COALESCE(vendor_branch_id, 0));
CREATE INDEX IF NOT EXISTS ix_auto_rfq_sends_quotation ON qvm_new_apps.auto_rfq_sends (quotation_id, status);

CREATE TABLE IF NOT EXISTS qvm_new_apps.auto_rfq_settings (
  key        text PRIMARY KEY,
  value      text,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO qvm_new_apps.auto_rfq_settings (key, value) VALUES
  -- This branch's own project: the dispatcher lives next to the database that wakes it.
  ('dispatch_url', 'https://exizrhlkxoqljiypzwyx.supabase.co/functions/v1/auto_rfq_dispatch'),
  ('app_origin', ''),
  ('debounce_seconds', '20')
ON CONFLICT (key) DO NOTHING;

-- The shared secret between the trigger and the dispatcher, minted once, never in a migration file.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'auto_rfq_dispatch_secret') THEN
    PERFORM vault.create_secret(gen_random_uuid()::text, 'auto_rfq_dispatch_secret',
                                'Shared secret between the auto-RFQ trigger and the auto_rfq_dispatch edge function');
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'auto_rfq: vault secret not created: %', SQLERRM;
END $$;

-- Seed the default brands from what the vendors' branches already declare (vendor_branches.brands,
-- car-brand ids), so nobody starts from a blank sheet. Only ids that are car brands are taken.
INSERT INTO qvm_new_apps.vendor_default_brands (vendor_id, brand_id)
SELECT DISTINCT vb.vendor_id, ld.list_data_id
  FROM qvm_new_apps.vendor_branches vb
  CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(vb.brands, '[]'::jsonb)) b(id)
  JOIN qvm_new_apps.list_data ld ON ld.list_id = 4 AND b.id ~ '^[0-9]+$' AND ld.list_data_id = b.id::integer
ON CONFLICT DO NOTHING;

------------------------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_assert_admin()
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin() THEN
    RAISE EXCEPTION 'Access denied: Qparts Admin only';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_status_name(p_status integer)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE p_status WHEN 235 THEN 'Ready for Quotation' WHEN 236 THEN 'Extract PN' ELSE p_status::text END $$;

------------------------------------------------------------------------------ admin: options
-- Everything the editor picks from: branches, car brands, vendors with their default brands and branches.
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
               'default_brand_ids', COALESCE((SELECT jsonb_agg(db.brand_id ORDER BY db.brand_id)
                                                FROM qvm_new_apps.vendor_default_brands db WHERE db.vendor_id = v.vendor_id), '[]'::jsonb),
               'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object('vendor_branch_id', vbr.vendor_branch_id,
                                                                          'branch_name', vbr.branch_name, 'city', vbr.city)
                                                     ORDER BY vbr.branch_name)
                                       FROM qvm_new_apps.vendor_branches vbr
                                      WHERE vbr.vendor_id = v.vendor_id AND vbr.is_active), '[]'::jsonb))
               ORDER BY v.vendor_name)
        FROM qvm_new_apps.vendors v
       WHERE COALESCE(v.receives_quotations, true)), '[]'::jsonb));
END $$;

------------------------------------------------------------------------------ admin: rules
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
                          -- ARFQ-6: outside the vendor's default brands → warning chip.
                          'covers_brand', EXISTS (SELECT 1 FROM qvm_new_apps.vendor_default_brands db
                                                   WHERE db.vendor_id = rv.vendor_id AND db.brand_id = r.brand_id))
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

-- Create or update. A second rule for the same branch + brand is refused with 'conflict' unless
-- p_merge is set, in which case the vendors and statuses are folded into the existing rule.
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

CREATE OR REPLACE FUNCTION qvm_new_apps.set_auto_rfq_rule_active(p_rule_id bigint, p_active boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  UPDATE qvm_new_apps.auto_rfq_rules SET is_active = COALESCE(p_active, false), updated_by = auth.uid(), updated_at = now()
   WHERE rule_id = p_rule_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'error', 'message', 'That rule no longer exists'); END IF;
  RETURN jsonb_build_object('status', 'success', 'active_count', (SELECT count(*) FROM qvm_new_apps.auto_rfq_rules WHERE is_active));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_auto_rfq_rule(p_rule_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  -- Sends already made keep their history (rule_id set null by the FK); nothing sent is touched.
  DELETE FROM qvm_new_apps.auto_rfq_rules WHERE rule_id = p_rule_id;
  RETURN jsonb_build_object('status', 'success', 'deleted', FOUND);
END $$;

------------------------------------------------------------------------------ admin: vendor default brands
CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_default_brands()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN jsonb_build_object(
    'brands', COALESCE((SELECT jsonb_agg(jsonb_build_object('brand_id', ld.list_data_id, 'name', ld.list_data) ORDER BY ld.list_data)
                          FROM qvm_new_apps.list_data ld WHERE ld.list_id = 4), '[]'::jsonb),
    'vendors', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'vendor_id', v.vendor_id, 'vendor_name', v.vendor_name,
               'brand_ids', COALESCE((SELECT jsonb_agg(db.brand_id ORDER BY db.brand_id)
                                        FROM qvm_new_apps.vendor_default_brands db WHERE db.vendor_id = v.vendor_id), '[]'::jsonb),
               'rules_count', (SELECT count(DISTINCT rv.rule_id) FROM qvm_new_apps.auto_rfq_rule_vendors rv WHERE rv.vendor_id = v.vendor_id))
               ORDER BY v.vendor_name)
        FROM qvm_new_apps.vendors v), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_default_brands(p_vendor_id integer, p_brand_ids integer[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_vendor_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unknown vendor');
  END IF;
  DELETE FROM qvm_new_apps.vendor_default_brands WHERE vendor_id = p_vendor_id
     AND NOT (brand_id = ANY(COALESCE(p_brand_ids, ARRAY[]::integer[])));
  INSERT INTO qvm_new_apps.vendor_default_brands (vendor_id, brand_id, created_by)
  SELECT p_vendor_id, b, auth.uid() FROM unnest(COALESCE(p_brand_ids, ARRAY[]::integer[])) b
   WHERE EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = b AND ld.list_id = 4)
  ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('status', 'success', 'vendor_id', p_vendor_id,
           'brand_ids', COALESCE((SELECT jsonb_agg(db.brand_id ORDER BY db.brand_id) FROM qvm_new_apps.vendor_default_brands db WHERE db.vendor_id = p_vendor_id), '[]'::jsonb));
END $$;

------------------------------------------------------------------------------ admin: sends log + settings
CREATE OR REPLACE FUNCTION qvm_new_apps.list_auto_rfq_sends(p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(x.payload ORDER BY x.created_at DESC) FROM (
      SELECT s.created_at, jsonb_build_object(
               'send_id', s.send_id, 'rule_id', s.rule_id, 'quotation_id', s.quotation_id,
               'order_number', q.order_number, 'quotation_item_id', s.quotation_item_id,
               'part_number', qi.part_number, 'part_description', qi.part_description,
               'vendor_id', s.vendor_id, 'vendor_name', v.vendor_name, 'vendor_branch_id', s.vendor_branch_id,
               'trigger_status', s.trigger_status, 'trigger_status_name', qvm_new_apps.auto_rfq_status_name(s.trigger_status),
               'status', s.status, 'error', s.error, 'webhook_log_id', s.webhook_log_id,
               'created_at', s.created_at, 'sent_at', s.sent_at) AS payload
        FROM qvm_new_apps.auto_rfq_sends s
        LEFT JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = s.quotation_item_id
        LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = s.vendor_id
       ORDER BY s.created_at DESC
       LIMIT GREATEST(COALESCE(p_limit, 100), 1)) x), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_auto_rfq_settings()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN COALESCE((SELECT jsonb_object_agg(s.key, s.value) FROM qvm_new_apps.auto_rfq_settings s), '{}'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_auto_rfq_setting(p_key text, p_value text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  IF p_key NOT IN ('dispatch_url', 'app_origin', 'debounce_seconds') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unknown setting');
  END IF;
  INSERT INTO qvm_new_apps.auto_rfq_settings (key, value, updated_by, updated_at) VALUES (p_key, p_value, auth.uid(), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  RETURN jsonb_build_object('status', 'success');
END $$;

-- Failed sends of an order go back to the queue; the page then wakes the dispatcher.
CREATE OR REPLACE FUNCTION qvm_new_apps.retry_auto_rfq_sends(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v_n integer;
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  UPDATE qvm_new_apps.auto_rfq_sends SET status = 'queued', error = NULL
   WHERE quotation_id = p_quotation_id AND status = 'failed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status', 'success', 'requeued', v_n);
END $$;

------------------------------------------------------------------------------ the dispatcher's side (service role only)
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_secret_ok(p_secret text)
 RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v text;
BEGIN
  SELECT decrypted_secret INTO v FROM vault.decrypted_secrets WHERE name = 'auto_rfq_dispatch_secret';
  RETURN v IS NOT NULL AND p_secret IS NOT NULL AND v = p_secret;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

-- Claims the order's queued rows atomically: two dispatchers cannot both send the same row.
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_claim(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v jsonb;
BEGIN
  -- A data-modifying CTE has to be the statement's top level, hence the INTO rather than a subselect.
  WITH c AS (
    UPDATE qvm_new_apps.auto_rfq_sends s SET status = 'sending'
     WHERE s.quotation_id = p_quotation_id AND s.status = 'queued'
    RETURNING s.send_id, s.rule_id, s.quotation_item_id, s.vendor_id, s.vendor_branch_id, s.trigger_status)
  SELECT jsonb_agg(to_jsonb(c)) INTO v FROM c;
  RETURN COALESCE(v, '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_mark(p_send_ids bigint[], p_status text, p_error text DEFAULT NULL, p_webhook_log_id bigint DEFAULT NULL)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
  UPDATE qvm_new_apps.auto_rfq_sends
     SET status = p_status, error = p_error, webhook_log_id = COALESCE(p_webhook_log_id, webhook_log_id),
         sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE sent_at END
   WHERE send_id = ANY(p_send_ids);
$$;

-- What the dispatcher needs to build the same payload a manual send builds.
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_payload(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
  SELECT jsonb_build_object(
    'order', (SELECT jsonb_build_object('quotation_id', q.quotation_id, 'order_number', q.order_number,
                                        'plate_number', q.plate_number, 'created_at', q.created_at)
                FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id),
    'car', (SELECT jsonb_build_object('vin', qi.vin, 'make', mb.list_data, 'model', qi.model, 'year', qi.year)
              FROM qvm_new_apps.quotation_items qi
              LEFT JOIN qvm_new_apps.list_data mb ON mb.list_data_id = qi.main_brand
             WHERE qi.quotation_id = p_quotation_id
             ORDER BY (qi.vin IS NOT NULL) DESC, qi.quotation_item_id LIMIT 1),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                         'quotation_item_id', qi.quotation_item_id, 'part_number', qi.part_number,
                         'part_description', qi.part_description, 'class', bc.list_data, 'qty', qi.quantity)
                         ORDER BY qi.quotation_item_id)
                         FROM qvm_new_apps.quotation_items qi
                         LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = qi.brand_class
                        WHERE qi.quotation_id = p_quotation_id), '[]'::jsonb),
    'settings', (SELECT jsonb_object_agg(s.key, s.value) FROM qvm_new_apps.auto_rfq_settings s),
    'vendors', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                           'vendor_id', v.vendor_id, 'vendor_name', v.vendor_name, 'email', v.email,
                           'phone_numbers', v.phone_numbers,
                           'branches', COALESCE((SELECT jsonb_agg(jsonb_build_object('vendor_branch_id', b.vendor_branch_id, 'phone', b.phone))
                                                   FROM qvm_new_apps.vendor_branches b WHERE b.vendor_id = v.vendor_id), '[]'::jsonb)))
                           FROM qvm_new_apps.vendors v
                          WHERE v.vendor_id IN (SELECT DISTINCT s.vendor_id FROM qvm_new_apps.auto_rfq_sends s WHERE s.quotation_id = p_quotation_id)), '[]'::jsonb));
$$;

------------------------------------------------------------------------------ the trigger
CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_on_item_status()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE
  v_n      integer := 0;
  v_url    text;
  v_secret text;
BEGIN
  IF NEW.item_status IS NULL OR NEW.item_status NOT IN (235, 236) THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.item_status IS NOT DISTINCT FROM NEW.item_status THEN RETURN NEW; END IF;
  IF NEW.customer_id IS NULL OR NEW.main_brand IS NULL THEN RETURN NEW; END IF;

  WITH ins AS (
    INSERT INTO qvm_new_apps.auto_rfq_sends (rule_id, quotation_id, quotation_item_id, vendor_id, vendor_branch_id, trigger_status)
    SELECT r.rule_id, NEW.quotation_id, NEW.quotation_item_id, rv.vendor_id, rv.vendor_branch_id, NEW.item_status
      FROM qvm_new_apps.auto_rfq_rules r
      JOIN qvm_new_apps.auto_rfq_rule_vendors rv ON rv.rule_id = r.rule_id
     WHERE r.is_active
       AND r.customer_id = NEW.customer_id
       AND r.brand_id = NEW.main_brand
       AND NEW.item_status = ANY(r.trigger_statuses)
       -- A line somebody already sent this vendor by hand is not asked again.
       AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_items qvi
                         JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
                        WHERE qvi.quotation_item_id = NEW.quotation_item_id
                          AND qv.vendor_id = rv.vendor_id
                          AND qv.vendor_branch_id IS NOT DISTINCT FROM rv.vendor_branch_id)
    ON CONFLICT DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;

  IF v_n > 0 THEN
    SELECT s.value INTO v_url FROM qvm_new_apps.auto_rfq_settings s WHERE s.key = 'dispatch_url';
    BEGIN
      SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'auto_rfq_dispatch_secret';
    EXCEPTION WHEN OTHERS THEN v_secret := NULL; END;
    IF NULLIF(btrim(COALESCE(v_url, '')), '') IS NOT NULL AND v_secret IS NOT NULL THEN
      BEGIN
        PERFORM net.http_post(
          url     := v_url,
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-auto-rfq-secret', v_secret),
          body    := jsonb_build_object('quotation_id', NEW.quotation_id));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Automation never blocks the order it is trying to help.
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_auto_rfq_on_item_status ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_auto_rfq_on_item_status
AFTER INSERT OR UPDATE OF item_status ON qvm_new_apps.quotation_items
FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.auto_rfq_on_item_status();

------------------------------------------------------------------------------ the send's cancelled-line check, as the send function expects it
-- Written in 20260910100000 but never applied on test (the branch's runner has failed since March);
-- the send function below calls it, so it is (re)created here — dependency-free, idempotent.
CREATE OR REPLACE FUNCTION qvm_new_apps.assert_items_sendable(p_quotation_items jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT string_agg(DISTINCT COALESCE(qi.part_number, qi.part_description, qi.quotation_item_id::text), ', ')
  FROM jsonb_array_elements(p_quotation_items) e
  JOIN qvm_new_apps.quotation_items qi
    ON qi.quotation_item_id = NULLIF(e->>'quotation_item_id','')::bigint
  WHERE qi.item_status = 18;   -- Canceled
$function$;

------------------------------------------------------------------------------ a send adds to a vendor's lines, never replaces them
CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendors_quotations(p_vendor_selections jsonb, p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_selection           JSONB;
  v_vendor_id           BIGINT;
  v_vendor_branch_id    BIGINT;
  v_quotation_vendor_id BIGINT;
  v_access_token        UUID;
  v_results             JSONB := '[]'::jsonb;
  rec                   JSONB;
  v_item_id             BIGINT;
  v_cost                NUMERIC;
  v_from_database       BOOLEAN;
  v_discount            NUMERIC;
  v_vendor_item_status  INTEGER;
  v_new_cost_id         BIGINT;
BEGIN
  IF p_vendor_selections IS NULL OR jsonb_typeof(p_vendor_selections) <> 'array' OR jsonb_array_length(p_vendor_selections) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_vendor_selections must be a non-empty JSON array');
  END IF;

  IF p_quotation_items IS NULL OR jsonb_typeof(p_quotation_items) <> 'array' OR jsonb_array_length(p_quotation_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_quotation_items must be a non-empty JSON array');
  END IF;

  -- A cancelled line is not something a vendor should be asked to price. Refused as a whole rather
  -- than skipped quietly: sending an RFQ is one action, and silently dropping lines from it would
  -- leave the sender believing they had asked for something they had not.
  DECLARE v_cancelled text;
  BEGIN
    v_cancelled := qvm_new_apps.assert_items_sendable(p_quotation_items);
    IF v_cancelled IS NOT NULL THEN
      RETURN jsonb_build_object('status', false,
        'message', 'Cancelled items cannot be sent to a vendor: ' || v_cancelled);
    END IF;
  END;

  FOR v_selection IN SELECT * FROM jsonb_array_elements(p_vendor_selections) LOOP
    v_vendor_id        := (v_selection->>'vendor_id')::BIGINT;
    v_vendor_branch_id := NULLIF(v_selection->>'vendor_branch_id', '')::BIGINT;

    SELECT quotation_vendor_id, access_token
    INTO v_quotation_vendor_id, v_access_token
    FROM qvm_new_apps.quotation_vendors
    WHERE vendor_id = v_vendor_id
      AND quotation_id = p_quotation_id
      AND vendor_branch_id IS NOT DISTINCT FROM v_vendor_branch_id
    LIMIT 1;

    IF v_quotation_vendor_id IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, vendor_branch_id, quotation_id, created_at)
      VALUES (v_vendor_id, v_vendor_branch_id, p_quotation_id, NOW())
      RETURNING quotation_vendor_id, access_token INTO v_quotation_vendor_id, v_access_token;
    ELSE
      -- Resend: keep the same link working, just push its expiry out another 7 days.
      UPDATE qvm_new_apps.quotation_vendors
      SET token_expires_at = now() + interval '7 days'
      WHERE quotation_vendor_id = v_quotation_vendor_id;
    END IF;

    -- The vendor's existing lines stay. A line's cost_id is what purchase items, the cost log and
    -- the buyer's picks hang from; replacing the rows broke the first and orphaned the rest, and an
    -- automatic send of one new line must never discard what the vendor already priced.

    FOR rec IN SELECT * FROM jsonb_array_elements(p_quotation_items) LOOP
      v_item_id            := (rec->>'quotation_item_id')::BIGINT;
      v_cost               := NULLIF(rec->>'cost','')::NUMERIC;
      v_discount           := NULLIF(rec->>'discount_percent','')::NUMERIC;
      v_from_database      := (rec->>'from_database')::BOOLEAN;
      v_vendor_item_status := (rec->>'vendor_item_status')::INTEGER;

      INSERT INTO qvm_new_apps.quotation_vendor_items (
        quotation_item_id, vendor_id, quotation_vendor_id,
        best_cost, cost, discount_percent, from_database,
        vendor_item_status, created_at, updated_at
      )
      VALUES (
        v_item_id, v_vendor_id, v_quotation_vendor_id,
        FALSE, v_cost, v_discount, v_from_database,
        v_vendor_item_status, NOW(), NOW()
      )
      ON CONFLICT (quotation_item_id, quotation_vendor_id) DO UPDATE
      -- A resend that carries no price is a re-ask, not a wipe.
      SET cost = COALESCE(EXCLUDED.cost, quotation_vendor_items.cost),
          discount_percent = COALESCE(EXCLUDED.discount_percent, quotation_vendor_items.discount_percent),
          from_database = COALESCE(EXCLUDED.from_database, quotation_vendor_items.from_database),
          vendor_item_status = CASE WHEN EXCLUDED.cost IS NULL AND quotation_vendor_items.cost IS NOT NULL
                                    THEN quotation_vendor_items.vendor_item_status
                                    ELSE EXCLUDED.vendor_item_status END,
          updated_at = NOW()
      RETURNING cost_id INTO v_new_cost_id;

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'quotation_vendor_id', v_quotation_vendor_id,
          'vendor_id', v_vendor_id,
          'vendor_branch_id', v_vendor_branch_id,
          'access_token', v_access_token,
          'quotation_id', p_quotation_id,
          'quotation_item_id', v_item_id,
          'cost_id', v_new_cost_id,
          'inserted', v_new_cost_id IS NOT NULL
        )
      );

    END LOOP;

  END LOOP;

  -- Update selected quotation items status to "Sent To Vendor" — but never downgrade an item
  -- that's already further along (Priced or beyond): tendering it to one more vendor shouldn't
  -- visually reset its progress.
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  ),
  updated_items AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET item_status = 237,
        updated_at = now()
    FROM sent_items si
    WHERE qi.quotation_item_id = si.quotation_item_id
      AND (qi.item_status IS NULL OR qi.item_status NOT IN (17, 19, 21, 22, 23, 31))
    RETURNING qi.quotation_item_id
  )
  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT quotation_item_id, 237, auth.uid(), now()
  FROM updated_items
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;
$function$;

------------------------------------------------------------------------------ wrappers + grants
CREATE OR REPLACE FUNCTION public.list_auto_rfq_options() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_auto_rfq_options() $$;
CREATE OR REPLACE FUNCTION public.list_auto_rfq_rules() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_auto_rfq_rules() $$;
CREATE OR REPLACE FUNCTION public.save_auto_rfq_rule(p_rule_id bigint, p_customer_id integer, p_brand_id integer, p_vendors jsonb, p_statuses integer[], p_merge boolean DEFAULT false) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.save_auto_rfq_rule(p_rule_id, p_customer_id, p_brand_id, p_vendors, p_statuses, p_merge) $$;
CREATE OR REPLACE FUNCTION public.set_auto_rfq_rule_active(p_rule_id bigint, p_active boolean) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.set_auto_rfq_rule_active(p_rule_id, p_active) $$;
CREATE OR REPLACE FUNCTION public.delete_auto_rfq_rule(p_rule_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.delete_auto_rfq_rule(p_rule_id) $$;
CREATE OR REPLACE FUNCTION public.list_vendor_default_brands() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_vendor_default_brands() $$;
CREATE OR REPLACE FUNCTION public.set_vendor_default_brands(p_vendor_id integer, p_brand_ids integer[]) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.set_vendor_default_brands(p_vendor_id, p_brand_ids) $$;
CREATE OR REPLACE FUNCTION public.list_auto_rfq_sends(p_limit integer DEFAULT 100) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_auto_rfq_sends(p_limit) $$;
CREATE OR REPLACE FUNCTION public.get_auto_rfq_settings() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.get_auto_rfq_settings() $$;
CREATE OR REPLACE FUNCTION public.set_auto_rfq_setting(p_key text, p_value text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.set_auto_rfq_setting(p_key, p_value) $$;
CREATE OR REPLACE FUNCTION public.retry_auto_rfq_sends(p_quotation_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.retry_auto_rfq_sends(p_quotation_id) $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.list_auto_rfq_options()', 'public.list_auto_rfq_rules()',
    'public.save_auto_rfq_rule(bigint, integer, integer, jsonb, integer[], boolean)',
    'public.set_auto_rfq_rule_active(bigint, boolean)', 'public.delete_auto_rfq_rule(bigint)',
    'public.list_vendor_default_brands()', 'public.set_vendor_default_brands(integer, integer[])',
    'public.list_auto_rfq_sends(integer)', 'public.get_auto_rfq_settings()', 'public.set_auto_rfq_setting(text, text)',
    'public.retry_auto_rfq_sends(bigint)',
    'qvm_new_apps.list_auto_rfq_options()', 'qvm_new_apps.list_auto_rfq_rules()',
    'qvm_new_apps.save_auto_rfq_rule(bigint, integer, integer, jsonb, integer[], boolean)',
    'qvm_new_apps.set_auto_rfq_rule_active(bigint, boolean)', 'qvm_new_apps.delete_auto_rfq_rule(bigint)',
    'qvm_new_apps.list_vendor_default_brands()', 'qvm_new_apps.set_vendor_default_brands(integer, integer[])',
    'qvm_new_apps.list_auto_rfq_sends(integer)', 'qvm_new_apps.get_auto_rfq_settings()', 'qvm_new_apps.set_auto_rfq_setting(text, text)',
    'qvm_new_apps.retry_auto_rfq_sends(bigint)', 'qvm_new_apps.auto_rfq_assert_admin()']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
  -- The dispatcher's functions: the service role and nobody else.
  FOREACH f IN ARRAY ARRAY['qvm_new_apps.auto_rfq_secret_ok(text)', 'qvm_new_apps.auto_rfq_claim(bigint)',
                           'qvm_new_apps.auto_rfq_mark(bigint[], text, text, bigint)', 'qvm_new_apps.auto_rfq_payload(bigint)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.vendor_default_brands, qvm_new_apps.auto_rfq_rules,
  qvm_new_apps.auto_rfq_rule_vendors, qvm_new_apps.auto_rfq_sends, qvm_new_apps.auto_rfq_settings TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.auto_rfq_rules_rule_id_seq, qvm_new_apps.auto_rfq_sends_send_id_seq TO service_role;
