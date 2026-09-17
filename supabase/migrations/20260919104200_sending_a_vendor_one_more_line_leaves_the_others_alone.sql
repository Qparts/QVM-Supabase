-- Sending a vendor one more line leaves their other lines alone.
--
-- create_vendors_quotations replaced the vendor's rows on every send: delete them all, insert the
-- payload. A line's cost_id is what purchase items, approval items, the vendor's alternatives, the
-- buyer's picks and the cost log hang from — so once anything on the order had been bought, sending
-- the same vendor a new line failed on the purchase-items foreign key, and before that it had been
-- quietly discarding the vendor's other priced lines. Now existing lines stay; the payload's lines
-- are inserted or refreshed, and a refresh that carries no price keeps the one the vendor gave.
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

    -- The vendor's existing lines stay. A line's cost_id is what purchase items, approval items, the
    -- vendor's alternatives, the buyer's picks and the cost log all hang from; replacing the rows
    -- broke the first of those and silently orphaned the rest. Lines in the payload are inserted or
    -- refreshed below; lines not in it are left exactly as they were.

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
      -- A resend that carries no price is a re-ask, not a wipe: the price the vendor gave, and the
      -- status that goes with it, survive it.
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

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 16 $$;
