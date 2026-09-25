-- A company sets when its supervisors are asked.
--
-- Two rules send a purchase to the supervisor ladder, and until now the first was fixed in the
-- pricing page and the second did not exist:
--
--   1. The price from a vendor is above the last price the company paid THAT vendor for the same
--      part, by more than a set percentage, where that purchase happened within a set number of
--      days. (Before: any increase, over any vendor, at any time.)
--   2. Fewer than a set number of vendors priced the item. A single quote is not a market, so the
--      line cannot go out for confirmation or be bought until a supervisor agrees.
--
-- Each rule has a switch and its figures, per company. A company that never opened the screen
-- keeps rule 1 on at 0% over 365 days — which is today's behaviour narrowed to the same vendor —
-- and rule 2 off, so nothing new is blocked until an admin decides it should be.
--
-- Only the company's own admin and the Qparts Admin change these. Anyone pricing for the company
-- may read them: the pricing page has to know the rules it is enforcing.

CREATE TABLE IF NOT EXISTS qvm_new_apps.company_pricing_rules (
  company_id          integer PRIMARY KEY REFERENCES qvm_new_apps.client_companies(company_id) ON DELETE CASCADE,
  price_rise_enabled  boolean      NOT NULL DEFAULT true,
  price_rise_pct      numeric(7,2) NOT NULL DEFAULT 0   CHECK (price_rise_pct >= 0 AND price_rise_pct <= 1000),
  price_rise_days     integer      NOT NULL DEFAULT 365 CHECK (price_rise_days BETWEEN 1 AND 3650),
  min_vendors_enabled boolean      NOT NULL DEFAULT false,
  min_vendors         integer      NOT NULL DEFAULT 3   CHECK (min_vendors BETWEEN 2 AND 50),
  updated_by          uuid,
  updated_at          timestamptz  NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.company_pricing_rules TO service_role;

-- The rules in force for a company: its own row, or the defaults above when it has none.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_company_pricing_rules(p_company_id integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE r qvm_new_apps.company_pricing_rules;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  SELECT * INTO r FROM qvm_new_apps.company_pricing_rules WHERE company_id = p_company_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'company_id',          p_company_id,
    'is_default',          r.company_id IS NULL,
    'can_edit',            p_company_id IS NOT NULL AND qvm_new_apps.can_admin_company(p_company_id),
    'price_rise_enabled',  COALESCE(r.price_rise_enabled, true),
    'price_rise_pct',      COALESCE(r.price_rise_pct, 0),
    'price_rise_days',     COALESCE(r.price_rise_days, 365),
    'min_vendors_enabled', COALESCE(r.min_vendors_enabled, false),
    'min_vendors',         COALESCE(r.min_vendors, 3),
    'updated_at',          r.updated_at,
    'updated_by_name',     (SELECT ud.user_name FROM qvm_new_apps.user_data ud WHERE ud.user_id = r.updated_by)));
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_company_pricing_rules(p_company_id integer, p_rules jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_pct numeric; v_days int; v_min int;
BEGIN
  IF p_company_id IS NULL OR NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: only this company''s admin or the Qparts admin can change these rules');
  END IF;
  v_pct  := COALESCE(NULLIF(p_rules->>'price_rise_pct', '')::numeric, 0);
  v_days := COALESCE(NULLIF(p_rules->>'price_rise_days', '')::int, 365);
  v_min  := COALESCE(NULLIF(p_rules->>'min_vendors', '')::int, 3);
  IF v_pct < 0 OR v_pct > 1000 THEN RETURN jsonb_build_object('success', false, 'error', 'The percentage must be between 0 and 1000'); END IF;
  IF v_days < 1 OR v_days > 3650 THEN RETURN jsonb_build_object('success', false, 'error', 'The days must be between 1 and 3650'); END IF;
  IF v_min < 2 OR v_min > 50 THEN RETURN jsonb_build_object('success', false, 'error', 'The number of vendors must be between 2 and 50'); END IF;
  INSERT INTO qvm_new_apps.company_pricing_rules
    (company_id, price_rise_enabled, price_rise_pct, price_rise_days, min_vendors_enabled, min_vendors, updated_by, updated_at)
  VALUES (p_company_id,
          COALESCE((p_rules->>'price_rise_enabled')::boolean, true), v_pct, v_days,
          COALESCE((p_rules->>'min_vendors_enabled')::boolean, false), v_min,
          auth.uid(), now())
  ON CONFLICT (company_id) DO UPDATE
    SET price_rise_enabled = EXCLUDED.price_rise_enabled, price_rise_pct = EXCLUDED.price_rise_pct,
        price_rise_days = EXCLUDED.price_rise_days, min_vendors_enabled = EXCLUDED.min_vendors_enabled,
        min_vendors = EXCLUDED.min_vendors, updated_by = EXCLUDED.updated_by, updated_at = now();
  RETURN qvm_new_apps.get_company_pricing_rules(p_company_id);
END $$;

-- What the pricing page needs to apply rule 1 on one order: for every vendor line on it, the last
-- price the company paid that same vendor for that same part, inside the company's window. Keyed
-- by cost_id, which is what a selected cell carries. A line with no such purchase is absent.
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_rule_checks(p_quotation_id integer, p_company_id integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_rules jsonb; v_days int; v_last jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  v_rules := qvm_new_apps.get_company_pricing_rules(p_company_id)->'data';
  v_days  := COALESCE((v_rules->>'price_rise_days')::int, 365);
  WITH offers AS (
    SELECT qvi.cost_id, qvi.vendor_id, upper(btrim(qi.part_number)) AS pn
      FROM qvm_new_apps.quotation_vendor_items qvi
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = qvi.quotation_item_id
     WHERE qi.quotation_id = p_quotation_id
       AND qvi.vendor_id IS NOT NULL
       AND COALESCE(btrim(qi.part_number), '') <> ''
  ),
  bought AS (
    SELECT upper(btrim(qi.part_number)) AS pn,
           COALESCE(po.vendor_id, qvi.vendor_id) AS vendor_id,
           COALESCE(pi.final_purchase_price, qvi.cost) AS price,
           po.created_at AS bought_at,
           q.order_number,
           v.vendor_name
      FROM qvm_new_apps.purchase_items pi
      JOIN qvm_new_apps.purchase_orders po         ON po.purchase_order_id = pi.purchase_order_id
      JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
      JOIN qvm_new_apps.quotation_items qi         ON qi.quotation_item_id = qvi.quotation_item_id
      JOIN qvm_new_apps.quotations q               ON q.quotation_id = qi.quotation_id
      LEFT JOIN qvm_new_apps.vendors v             ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id)
     WHERE po.created_at >= now() - make_interval(days => v_days)
       AND qi.quotation_id <> p_quotation_id
       AND COALESCE(pi.final_purchase_price, qvi.cost) > 0
       AND upper(btrim(qi.part_number)) IN (SELECT pn FROM offers)
  ),
  latest AS (
    SELECT DISTINCT ON (o.cost_id) o.cost_id, b.price, b.bought_at, b.order_number, b.vendor_name
      FROM offers o JOIN bought b ON b.pn = o.pn AND b.vendor_id = o.vendor_id
     ORDER BY o.cost_id, b.bought_at DESC
  )
  SELECT COALESCE(jsonb_object_agg(l.cost_id::text, jsonb_build_object(
           'price', l.price, 'bought_at', l.bought_at, 'order_number', l.order_number, 'vendor_name', l.vendor_name)), '{}'::jsonb)
    INTO v_last FROM latest l;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('rules', v_rules, 'last_by_cost', v_last));
END $$;

CREATE OR REPLACE FUNCTION public.get_company_pricing_rules(p_company_id integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.get_company_pricing_rules(p_company_id) $$;
CREATE OR REPLACE FUNCTION public.set_company_pricing_rules(p_company_id integer, p_rules jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.set_company_pricing_rules(p_company_id, p_rules) $$;
CREATE OR REPLACE FUNCTION public.pricing_rule_checks(p_quotation_id integer, p_company_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.pricing_rule_checks(p_quotation_id, p_company_id) $$;
