-- A vendor's price list, uploaded once instead of asked for every time.
--
-- Today the only way a vendor's cost reaches a quotation is an RFQ: mail the vendor, wait, and hope
-- they answer. For the vendors the team buys from constantly that is a round trip for a number
-- nobody disputes. This is the other route — the team uploads the vendor's list, and any part on a
-- quotation that the list already covers gets priced from it without anyone being emailed.
--
-- Deliberately a separate table from quotation_vendor_items. A vendor_costs row is a standing fact
-- about a vendor's catalogue; a quotation_vendor_item is one vendor's answer on one order. Folding
-- the first into the second would mean inventing quotation rows for parts nobody has asked about.

CREATE TABLE IF NOT EXISTS qvm_new_apps.vendor_costs (
  vendor_cost_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vendor_id             integer NOT NULL REFERENCES qvm_new_apps.vendors(vendor_id) ON DELETE CASCADE,
  part_number           text    NOT NULL,
  -- The same two numbers the pricing page already works in: after-discount is the wholesale price
  -- a purchase order is written against, before-discount is what can be adopted as the customer's.
  price_after_discount  numeric(12,2),
  price_before_discount numeric(12,2),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid
);

-- One row per vendor per part, matched the way part numbers are actually written: case and
-- surrounding space are noise, and without this "  ab-123 " and "AB-123" would be two prices for
-- one part and the later upload would not replace the earlier.
CREATE UNIQUE INDEX IF NOT EXISTS uq_vendor_costs_vendor_part
  ON qvm_new_apps.vendor_costs (vendor_id, upper(btrim(part_number)));

GRANT ALL ON qvm_new_apps.vendor_costs TO service_role;

-- ── Uploading a list ──────────────────────────────────────────────────────────────────────────
--
-- The whole file in one call. Re-uploading for the same vendor is an upsert, because that is what
-- the team means by it: the new file is the current price list, so a part it repeats is repriced
-- and a part it adds is added. A part the new file omits is left alone rather than deleted — a
-- partial file is far more common than a vendor dropping a line from their catalogue, and deleting
-- on absence would quietly empty the list for anyone who uploaded one page of a spreadsheet.
CREATE OR REPLACE FUNCTION qvm_new_apps.upsert_vendor_costs(p_vendor_id integer, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_inserted integer := 0;
  v_updated  integer := 0;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can upload a vendor price list';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RETURN jsonb_build_object('status', 'success', 'inserted', 0, 'updated', 0);
  END IF;

  WITH incoming AS (
    -- DISTINCT ON guards against the file itself repeating a part: ON CONFLICT cannot update the
    -- same row twice in one statement, so a duplicated part number would abort the whole upload.
    -- The last occurrence wins, which is how a person reading the sheet top to bottom would read it.
    SELECT DISTINCT ON (upper(btrim(x->>'part_number')))
           btrim(x->>'part_number')                          AS part_number,
           NULLIF(x->>'price_after_discount','')::numeric    AS price_after_discount,
           NULLIF(x->>'price_before_discount','')::numeric   AS price_before_discount
      FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS e(x, ord)
     WHERE COALESCE(btrim(x->>'part_number'), '') <> ''
     ORDER BY upper(btrim(x->>'part_number')), e.ord DESC
  ),
  done AS (
    INSERT INTO qvm_new_apps.vendor_costs
      (vendor_id, part_number, price_after_discount, price_before_discount, updated_by)
    SELECT p_vendor_id, i.part_number, i.price_after_discount, i.price_before_discount, auth.uid()
      FROM incoming i
    ON CONFLICT (vendor_id, upper(btrim(part_number))) DO UPDATE
      SET part_number           = EXCLUDED.part_number,
          price_after_discount  = EXCLUDED.price_after_discount,
          price_before_discount = EXCLUDED.price_before_discount,
          updated_by            = EXCLUDED.updated_by,
          updated_at            = now()
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT count(*) FILTER (WHERE was_insert), count(*) FILTER (WHERE NOT was_insert)
    INTO v_inserted, v_updated
    FROM done;

  RETURN jsonb_build_object('status', 'success', 'inserted', v_inserted, 'updated', v_updated);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_costs(p_vendor_id integer, p_search text DEFAULT NULL, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT CASE WHEN qvm_new_apps.is_qparts_team() THEN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'vendor_cost_id',        c.vendor_cost_id,
             'part_number',           c.part_number,
             'price_after_discount',  c.price_after_discount,
             'price_before_discount', c.price_before_discount,
             'updated_at',            c.updated_at) ORDER BY c.part_number)
      FROM (SELECT * FROM qvm_new_apps.vendor_costs vc
             WHERE vc.vendor_id = p_vendor_id
               AND (p_search IS NULL OR p_search = '' OR vc.part_number ILIKE '%' || p_search || '%')
             ORDER BY vc.part_number
             LIMIT GREATEST(COALESCE(p_limit, 200), 1)) c), '[]'::jsonb)
  ELSE '[]'::jsonb END;
$function$;

-- ── Pricing a quotation from a list ───────────────────────────────────────────────────────────
--
-- Creates the vendor's quotation rows straight from their uploaded list, for the parts it covers
-- and no others. No email, no token, no waiting: the price is already known.
--
-- Lines the vendor already has on this order are repriced rather than duplicated — running this
-- twice, or running it after the vendor answered, must not leave two rows for one part. The status
-- goes to 158 (priced) because that is exactly what the row is, and price_source records where the
-- number came from so a figure nobody typed is never mistaken for one a vendor sent.
CREATE OR REPLACE FUNCTION qvm_new_apps.apply_vendor_costs_to_quotation(
  p_quotation_id integer, p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_qv_id    bigint;
  v_matched  integer := 0;
  v_priced   integer := 0;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can price an order from a vendor list';
  END IF;

  SELECT count(*) INTO v_matched
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.vendor_costs vc
      ON vc.vendor_id = p_vendor_id
     AND upper(btrim(vc.part_number)) = upper(btrim(qi.part_number))
   WHERE qi.quotation_id = p_quotation_id
     AND COALESCE(btrim(qi.part_number), '') <> '';

  IF v_matched = 0 THEN
    RETURN jsonb_build_object('status', 'success', 'matched', 0, 'priced', 0,
                              'message', 'This vendor''s list covers none of the parts on this order');
  END IF;

  -- Reuse the vendor's existing row for this order when there is one; a second quotation_vendors
  -- row for the same vendor and branch is what the branch-isolation work spent a migration undoing.
  SELECT qv.quotation_vendor_id INTO v_qv_id
    FROM qvm_new_apps.quotation_vendors qv
   WHERE qv.quotation_id = p_quotation_id
     AND qv.vendor_id = p_vendor_id
     AND (p_vendor_branch_id IS NULL OR qv.vendor_branch_id IS NOT DISTINCT FROM p_vendor_branch_id)
   ORDER BY qv.quotation_vendor_id
   LIMIT 1;

  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, vendor_branch_id, created_at)
    VALUES (p_vendor_id, p_quotation_id, p_vendor_branch_id, now())
    RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  WITH matched AS (
    SELECT qi.quotation_item_id,
           vc.price_after_discount  AS after_price,
           vc.price_before_discount AS before_price,
           CASE WHEN COALESCE(vc.price_before_discount, 0) > 0 AND vc.price_after_discount IS NOT NULL
                THEN round(((vc.price_before_discount - vc.price_after_discount) / vc.price_before_discount) * 100, 2)
           END AS discount_percent
      FROM qvm_new_apps.quotation_items qi
      JOIN qvm_new_apps.vendor_costs vc
        ON vc.vendor_id = p_vendor_id
       AND upper(btrim(vc.part_number)) = upper(btrim(qi.part_number))
     WHERE qi.quotation_id = p_quotation_id
       AND COALESCE(btrim(qi.part_number), '') <> ''
  ),
  updated AS (
    UPDATE qvm_new_apps.quotation_vendor_items qvi
       SET cost               = m.after_price,
           agency_price       = m.before_price,
           discount_percent   = m.discount_percent,
           vendor_item_status = 158,
           price_source       = 'vendor_costs',
           updated_at         = now()
      FROM matched m
     WHERE qvi.quotation_vendor_id = v_qv_id
       AND qvi.quotation_item_id = m.quotation_item_id
    RETURNING qvi.quotation_item_id
  ),
  inserted AS (
    INSERT INTO qvm_new_apps.quotation_vendor_items
      (quotation_item_id, vendor_id, quotation_vendor_id, cost, agency_price, discount_percent,
       vendor_item_status, price_source, best_cost, from_database, created_at, updated_at)
    SELECT m.quotation_item_id, p_vendor_id, v_qv_id, m.after_price, m.before_price, m.discount_percent,
           158, 'vendor_costs', false, true, now(), now()
      FROM matched m
     WHERE NOT EXISTS (SELECT 1 FROM updated u WHERE u.quotation_item_id = m.quotation_item_id)
    RETURNING quotation_item_id
  )
  SELECT (SELECT count(*) FROM updated) + (SELECT count(*) FROM inserted) INTO v_priced;

  PERFORM qvm_new_apps.update_vendor_status(v_qv_id);

  RETURN jsonb_build_object('status', 'success', 'matched', v_matched, 'priced', v_priced,
                            'quotation_vendor_id', v_qv_id);
END;
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.upsert_vendor_costs(p_vendor_id integer, p_rows jsonb)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.upsert_vendor_costs(p_vendor_id, p_rows); $$;

CREATE OR REPLACE FUNCTION public.list_vendor_costs(p_vendor_id integer, p_search text DEFAULT NULL, p_limit integer DEFAULT 200)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_vendor_costs(p_vendor_id, p_search, p_limit); $$;

CREATE OR REPLACE FUNCTION public.apply_vendor_costs_to_quotation(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.apply_vendor_costs_to_quotation(p_quotation_id, p_vendor_id, p_vendor_branch_id); $$;

REVOKE ALL ON FUNCTION public.upsert_vendor_costs(integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_vendor_costs(integer, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_vendor_costs_to_quotation(integer, integer, bigint) FROM PUBLIC;

-- No anon here: none of this is reachable from the magic link, and every one of these functions
-- is a Qparts-team act on a vendor's commercial terms.
GRANT EXECUTE ON FUNCTION public.upsert_vendor_costs(integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_vendor_costs(integer, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_vendor_costs_to_quotation(integer, integer, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.upsert_vendor_costs(integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_vendor_costs(integer, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.apply_vendor_costs_to_quotation(integer, integer, bigint) TO authenticated, service_role;
