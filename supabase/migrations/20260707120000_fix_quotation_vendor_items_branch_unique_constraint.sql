-- Root cause of "items: null" for a valid, non-expired magic-link token: quotation_vendor_items
-- had UNIQUE (quotation_item_id, vendor_id) — a constraint from before the vendor-branch model
-- existed. When the same vendor is sent the same item under a SECOND quotation_vendors row (a
-- different branch), create_vendors_quotations' INSERT ... ON CONFLICT (quotation_item_id, vendor_id)
-- DO UPDATE collided with the FIRST branch's existing row and silently updated it in place — the SET
-- clause never touches quotation_vendor_id, so the item stayed attached to the OLD quotation_vendor_id.
-- The NEW quotation_vendors row (the one the fresh token points to) ended up with zero rows in
-- quotation_vendor_items, which is exactly the "items: null" symptom. Its own preceding DELETE
-- (scoped to quotation_vendor_id = v_quotation_vendor_id) is a no-op for a brand-new row, so nothing
-- rescues it. Fix: scope uniqueness to (quotation_item_id, quotation_vendor_id) instead, which is
-- what the branch-routing model actually requires — the same vendor CAN legitimately hold the same
-- item under two different quotation_vendor_id rows (one per branch).
ALTER TABLE qvm_new_apps.quotation_vendor_items
  DROP CONSTRAINT quotation_vendor_items_quotation_item_vendor_unique;

ALTER TABLE qvm_new_apps.quotation_vendor_items
  ADD CONSTRAINT quotation_vendor_items_quotation_item_qv_unique
  UNIQUE (quotation_item_id, quotation_vendor_id);

-- Exact copy of create_vendors_quotations from 20260706190000_vendor_quotation_magic_link.sql,
-- with only the ON CONFLICT target changed to match the new constraint above.
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

    -- Replace: delete old items for this vendor so only newly selected items remain
    DELETE FROM qvm_new_apps.quotation_vendor_items
    WHERE vendor_id = v_vendor_id
      AND quotation_vendor_id = v_quotation_vendor_id;

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
      SET cost = EXCLUDED.cost,
          discount_percent = EXCLUDED.discount_percent,
          from_database = EXCLUDED.from_database,
          vendor_item_status = EXCLUDED.vendor_item_status,
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

  -- Update selected quotation items status to "Sent To Vendor"
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  )
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 237,
      updated_at = now()
  FROM sent_items si
  WHERE qi.quotation_item_id = si.quotation_item_id;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT (log_rec->>'quotation_item_id')::bigint, 237, auth.uid(), now()
  FROM jsonb_array_elements(p_quotation_items) log_rec
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;
$function$;
