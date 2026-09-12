-- A branch created in the admin UI can actually receive an order.
--
-- Creating a branch was only half the job. Raising a quotation on one needs four things, and a
-- branch made through the new screens had none of them — each failing later, in a different place,
-- with a message that does not name the branch:
--
--   1. client_branches.region_id       — create_quotation_with_items refuses with "Missing required
--                                        fields" if get_region_for_branch returns nothing.
--   2. order_number_sequences(company, region)
--                                      — generate_rfq_order_number raises "Order sequence not
--                                        configured for client X and region Y".
--   3. account_manager_allocations(branch, slot)
--                                      — get_account_manager returns 404 "No account manager
--                                        allocation found" BEFORE it ever looks at the fallbacks.
--   4. account_manager_branches(branch, slot)
--                                      — the fallback chain behind that allocation.
--
-- So the admin RPCs now provision all four, and what cannot be provisioned is REPORTED rather than
-- left to be discovered by whoever tries to raise the first order.

------------------------------------------------------------------------------ region, from the city
--
-- Two different meanings of "region" live in this database. cities.region_id is the administrative
-- region — Riyadh, Makkah, Asir, the 13 of them. client_branches.region_id points at list_data
-- list 2, which holds four commercial groupings — West, East, Riyadh, Central — used for order
-- numbering and account-manager coverage. Mapping between them is a business decision, so it is a
-- column somebody can change, not an expression buried in a function.

ALTER TABLE qvm_new_apps.regions
  ADD COLUMN IF NOT EXISTS commercial_region_id integer REFERENCES qvm_new_apps.list_data(list_data_id);

UPDATE qvm_new_apps.regions r
SET commercial_region_id = m.list_id
FROM (VALUES
  ('riyadh',   13),   -- Riyadh
  ('eastern',  12),   -- East
  ('qassim',   14),   -- Central
  ('hail',     14),   -- Central
  ('makkah',   11),   -- West
  ('madinah',  11),
  ('tabuk',    11),
  ('jouf',     11),
  ('northern', 11),
  ('asir',     11),
  ('bahah',    11),
  ('jazan',    11),
  ('najran',   11)
) AS m(code, list_id)
WHERE r.region_code = m.code AND r.commercial_region_id IS DISTINCT FROM m.list_id;

COMMENT ON COLUMN qvm_new_apps.regions.commercial_region_id IS
  'Which of the four commercial regions (list_data list 2) this administrative region bills under. '
  'Only four buckets exist, so the southern and northern regions currently fall under West; change '
  'the row when that stops being how the business groups them.';

------------------------------------------------------------------------------ order-number sequence

-- Order numbers are prefixed per (company, region): SWS22 is company 1, West. A pair with no row
-- cannot produce an order number at all, so the pair is created on demand with a prefix derived
-- from the company's name.
CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_order_number_sequence(
  p_company_id integer,
  p_region_id  integer
)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_prefix text;
  v_base   text;
  v_letter text;
  v_name   text;
  v_n      integer := 1;
BEGIN
  IF p_company_id IS NULL OR p_region_id IS NULL THEN RETURN NULL; END IF;

  SELECT ons.prefix INTO v_prefix
  FROM qvm_new_apps.order_number_sequences ons
  WHERE ons.lists_data_id = p_company_id AND ons.region_id = p_region_id;
  IF FOUND THEN RETURN v_prefix; END IF;

  -- Letters from the company's default-language name, so a person can read where an order came
  -- from. Arabic-only names leave nothing usable, hence the company-id fallback.
  SELECT d.name INTO v_name
  FROM qvm_new_apps.client_companies_descriptions d
  WHERE d.company_id = p_company_id AND d.language_id = qvm_new_apps.default_language_id();

  v_base := upper(regexp_replace(COALESCE(v_name, ''), '[^a-zA-Z]', '', 'g'));
  v_base := CASE WHEN length(v_base) >= 2 THEN left(v_base, 3) ELSE 'C' || p_company_id END;

  v_letter := CASE p_region_id WHEN 11 THEN 'W' WHEN 12 THEN 'E' WHEN 13 THEN 'R' WHEN 14 THEN 'C'
                               ELSE 'X' || p_region_id END;

  v_prefix := v_base || v_letter;
  WHILE EXISTS (SELECT 1 FROM qvm_new_apps.order_number_sequences WHERE prefix = v_prefix) LOOP
    v_n := v_n + 1;
    v_prefix := v_base || v_letter || v_n;
  END LOOP;

  INSERT INTO qvm_new_apps.order_number_sequences (lists_data_id, region_id, sequence_name, prefix)
  VALUES (p_company_id, p_region_id,
          lower(COALESCE(NULLIF(v_base, ''), 'c' || p_company_id)) || '_' || lower(v_letter) || '_seq',
          v_prefix);

  RETURN v_prefix;
END $$;

------------------------------------------------------------------------------ account manager

-- A branch with no allocation stops an order dead — get_account_manager returns 404 before it
-- reaches any fallback. There is no sensible way to invent an account manager, so the rule is:
-- copy the arrangement from a sibling branch of the same workshop, then from any branch of the
-- same company, and if neither exists, do nothing and let the readiness check say so.
CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_branch_account_manager(
  p_customer_id integer,
  p_manager     uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_source integer;
  v_slot   smallint;
BEGIN
  IF EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations WHERE customer_id = p_customer_id) THEN
    RETURN true;
  END IF;

  IF p_manager IS NULL THEN
    SELECT sib.customer_id INTO v_source
    FROM qvm_new_apps.client_branches sib
    WHERE sib.workshop_id = (SELECT workshop_id FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id)
      AND sib.customer_id <> p_customer_id
      AND EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a WHERE a.customer_id = sib.customer_id)
    ORDER BY sib.customer_id
    LIMIT 1;

    IF v_source IS NULL THEN
      SELECT sib.customer_id INTO v_source
      FROM qvm_new_apps.client_branches sib
      WHERE sib.list_data_id = (SELECT list_data_id FROM qvm_new_apps.client_branches WHERE customer_id = p_customer_id)
        AND sib.customer_id <> p_customer_id
        AND EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a WHERE a.customer_id = sib.customer_id)
      ORDER BY sib.customer_id
      LIMIT 1;
    END IF;

    IF v_source IS NULL THEN RETURN false; END IF;

    INSERT INTO qvm_new_apps.account_manager_allocations
      (customer_id, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, calculated_at)
    SELECT p_customer_id, a.slot_number, a.saturday, a.sunday, a.monday, a.tuesday, a.wednesday,
           a.thursday, now()
    FROM qvm_new_apps.account_manager_allocations a
    WHERE a.customer_id = v_source;

    INSERT INTO qvm_new_apps.account_manager_branches
      (customer_id, slot_number, main_account_manager, first_substitute, second_substitute, fallback_account_manager)
    SELECT p_customer_id, b.slot_number, b.main_account_manager, b.first_substitute,
           b.second_substitute, b.fallback_account_manager
    FROM qvm_new_apps.account_manager_branches b
    WHERE b.customer_id = v_source
      AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_branches x
                       WHERE x.customer_id = p_customer_id AND x.slot_number = b.slot_number);
    RETURN true;
  END IF;

  -- An explicit manager covers all three slots, every day. The slots exist for day-off rotation;
  -- one person with no rotation is the honest starting point, and the account-managers screen is
  -- where it gets refined.
  FOREACH v_slot IN ARRAY ARRAY[1, 2, 3]::smallint[] LOOP
    INSERT INTO qvm_new_apps.account_manager_allocations
      (customer_id, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, calculated_at)
    VALUES (p_customer_id, v_slot, p_manager, p_manager, p_manager, p_manager, p_manager, p_manager, now());
    INSERT INTO qvm_new_apps.account_manager_branches
      (customer_id, slot_number, main_account_manager)
    VALUES (p_customer_id, v_slot, p_manager)
    ON CONFLICT DO NOTHING;
  END LOOP;
  RETURN true;
END $$;

------------------------------------------------------------------------------ provision, and report

-- Everything a branch needs, for every company its workshop serves. Safe to call repeatedly.
CREATE OR REPLACE FUNCTION qvm_new_apps.provision_branch_for_quotations(
  p_customer_id integer,
  p_manager     uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_region integer;
  v_city   integer;
  v_ws     bigint;
  v_am     boolean;
  v_seqs   text[] := ARRAY[]::text[];
  r        record;
BEGIN
  SELECT cb.region_id, cb.city_id, cb.workshop_id INTO v_region, v_city, v_ws
  FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = p_customer_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Branch not found');
  END IF;

  -- The city knows its administrative region, and that maps to the commercial one.
  IF v_region IS NULL AND v_city IS NOT NULL THEN
    SELECT rg.commercial_region_id INTO v_region
    FROM qvm_new_apps.cities c JOIN qvm_new_apps.regions rg ON rg.region_id = c.region_id
    WHERE c.city_id = v_city;
    IF v_region IS NOT NULL THEN
      UPDATE qvm_new_apps.client_branches SET region_id = v_region, updated_at = now()
      WHERE customer_id = p_customer_id;
    END IF;
  END IF;

  -- One sequence per company the workshop serves, in this branch's region.
  IF v_region IS NOT NULL THEN
    FOR r IN SELECT wc.company_id FROM qvm_new_apps.workshop_companies wc WHERE wc.workshop_id = v_ws
    LOOP
      v_seqs := v_seqs || qvm_new_apps.ensure_order_number_sequence(r.company_id, v_region);
    END LOOP;
  END IF;

  v_am := qvm_new_apps.ensure_branch_account_manager(p_customer_id, p_manager);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'customer_id', p_customer_id,
    'region_id', v_region,
    'order_prefixes', to_jsonb(v_seqs),
    'account_manager_ready', v_am));
END $$;

-- What is still missing, in words a screen can show. Nothing is inferred: each item is the exact
-- condition the failing code checks.
CREATE OR REPLACE FUNCTION qvm_new_apps.branch_quotation_readiness(p_customer_id integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT jsonb_build_object(
    'ready', (b.region_id IS NOT NULL AND has_am.ok AND NOT EXISTS (
                SELECT 1 FROM qvm_new_apps.workshop_companies wc
                WHERE wc.workshop_id = b.workshop_id
                  AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.order_number_sequences ons
                                   WHERE ons.lists_data_id = wc.company_id AND ons.region_id = b.region_id))),
    'missing', (
      SELECT COALESCE(jsonb_agg(m), '[]'::jsonb) FROM (
        SELECT 'No region — the order cannot be numbered or routed' AS m WHERE b.region_id IS NULL
        UNION ALL
        SELECT 'No account manager assigned to this branch' WHERE NOT has_am.ok
        UNION ALL
        SELECT 'No order-number sequence for ' || COALESCE(vc.name, 'company ' || wc.company_id)
          FROM qvm_new_apps.workshop_companies wc
          LEFT JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = wc.company_id
         WHERE wc.workshop_id = b.workshop_id AND b.region_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.order_number_sequences ons
                            WHERE ons.lists_data_id = wc.company_id AND ons.region_id = b.region_id)
      ) s)
  )
  FROM qvm_new_apps.client_branches b
  CROSS JOIN LATERAL (
    SELECT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations a
                    WHERE a.customer_id = b.customer_id) AS ok
  ) has_am
  WHERE b.customer_id = p_customer_id;
$$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.provision_branch_for_quotations(integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.branch_quotation_readiness(integer) TO authenticated;
