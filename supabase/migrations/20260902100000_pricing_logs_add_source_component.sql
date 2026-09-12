-- Track which UI flow triggered a price_before_vat change, alongside who and when.
-- Each RPC that can change price_before_vat sets a transaction-local GUC right before its
-- UPDATE; the existing pricing-log trigger picks it up. Falls back to NULL for any update
-- path that doesn't set it (e.g. a raw admin/service-role fix).
ALTER TABLE qvm_new_apps.pricing_logs ADD COLUMN IF NOT EXISTS source_component text;

CREATE OR REPLACE FUNCTION qvm_new_apps.log_pricing_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_qid INT;
  v_new_price NUMERIC;
  v_old_price NUMERIC;
BEGIN
  IF NOT (to_jsonb(NEW) ? 'price_before_vat') THEN
    RETURN NEW;
  END IF;

  v_new_price := (to_jsonb(NEW)->>'price_before_vat')::NUMERIC;
  v_old_price := (to_jsonb(OLD)->>'price_before_vat')::NUMERIC;

  IF v_new_price IS DISTINCT FROM v_old_price THEN
    v_qid := (to_jsonb(NEW)->>'quotation_item_id')::INT;

    INSERT INTO qvm_new_apps.pricing_logs (quotation_item_id, price, created_by, created_at, source_component)
    VALUES (
      v_qid,
      v_new_price,
      (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid,
      NOW(),
      current_setting('app.pricing_source_component', true)
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- PricingPage's "Save all prices" bulk flow (pages/pricing/PricingPage.tsx)
CREATE OR REPLACE FUNCTION qvm_new_apps.update_quotation_item_prices_bulk(p_updates jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  updated jsonb;
BEGIN
  PERFORM set_config('app.pricing_source_component', 'PricingPage', true);

  WITH changes AS (
    SELECT
      (x->>'quotation_item_id')::int          AS quotation_item_id,
      (x->>'price_before_vat')::numeric        AS price_before_vat,
      NULLIF(x->>'agency_price','')::numeric    AS agency_price,
      NULLIF(x->>'discount_percent','')::numeric AS discount_percent
    FROM jsonb_array_elements(p_updates) AS x
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET
      price_before_vat       = c.price_before_vat,
      agency_price           = COALESCE(c.agency_price, qi.agency_price),
      discount_percent       = COALESCE(c.discount_percent, qi.discount_percent),
      total_price_before_vat = c.price_before_vat * qi.quantity,
      item_status            = CASE WHEN qi.item_status IS NULL OR qi.item_status IN (236, 235, 237) THEN 17 ELSE qi.item_status END,
      updated_at              = NOW()
    FROM changes c
    WHERE qi.quotation_item_id = c.quotation_item_id
    RETURNING qi.quotation_item_id, qi.price_before_vat, qi.agency_price, qi.discount_percent,
              qi.total_price_before_vat, qi.item_status
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(upd.*)), '[]'::jsonb)
  INTO updated
  FROM upd;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk price update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0),
    'updated', updated
  );
END;
$function$;

-- DeliveryNotePage's inline item-edit flow (pages/DeliveryNotePage.tsx)
CREATE OR REPLACE FUNCTION public.update_delivery_note_item_inline(
  p_user_id uuid,
  p_confirmed_item_id int,
  p_part_description text DEFAULT NULL,
  p_final_part_number text DEFAULT NULL,
  p_final_brand_class int DEFAULT NULL,
  p_delivered_qty int DEFAULT NULL,
  p_price_before_vat numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_qi_id int;
  v_co_id int;
  v_delivery_id int;
  v_old_price numeric;
BEGIN
  SELECT user_type INTO v_user_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  SELECT quotation_item_id, confirmed_order_id INTO v_qi_id, v_co_id FROM qvm_new_apps.confirmed_items WHERE confirmed_item_id = p_confirmed_item_id;

  IF p_part_description IS NOT NULL THEN
    UPDATE qvm_new_apps.quotation_items SET part_description = p_part_description WHERE quotation_item_id = v_qi_id;
  END IF;

  IF p_final_part_number IS NOT NULL THEN
    UPDATE qvm_new_apps.confirmed_items SET final_part_number = p_final_part_number WHERE confirmed_item_id = p_confirmed_item_id;
  END IF;

  IF p_final_brand_class IS NOT NULL THEN
    UPDATE qvm_new_apps.confirmed_items SET final_brand_class = p_final_brand_class WHERE confirmed_item_id = p_confirmed_item_id;
  END IF;

  IF p_price_before_vat IS NOT NULL THEN
    PERFORM set_config('app.pricing_source_component', 'DeliveryNotePage', true);
    SELECT price_before_vat INTO v_old_price FROM qvm_new_apps.quotation_items WHERE quotation_item_id = v_qi_id;
    UPDATE qvm_new_apps.quotation_items SET price_before_vat = p_price_before_vat WHERE quotation_item_id = v_qi_id;
    -- Log the change as internal note
    IF v_old_price IS DISTINCT FROM p_price_before_vat THEN
      INSERT INTO qvm_new_apps.notes(note_description, note_type, type_id, is_internal, user_id, status)
      VALUES (concat('PBV changed from ', COALESCE(v_old_price::text,'NULL'), ' to ', COALESCE(p_price_before_vat::text,'NULL')), 'quotation_items', v_qi_id, true, p_user_id, 'system');
    END IF;
  END IF;

  IF p_delivered_qty IS NOT NULL THEN
    -- Ensure there is a delivery for this order
    SELECT d.delivery_id INTO v_delivery_id FROM qvm_new_apps.deliveries d WHERE d.confirmed_order_id = v_co_id ORDER BY d.delivery_date DESC NULLS LAST, d.delivery_id DESC LIMIT 1;
    IF v_delivery_id IS NULL THEN
      INSERT INTO qvm_new_apps.deliveries(confirmed_order_id, delivery_date)
      VALUES (v_co_id, NULL) RETURNING delivery_id INTO v_delivery_id;
    END IF;

    INSERT INTO qvm_new_apps.delivery_items(delivery_id, confirmed_item_id, delivered_qty)
    VALUES (v_delivery_id, p_confirmed_item_id, p_delivered_qty)
    ON CONFLICT (delivery_id, confirmed_item_id) DO UPDATE SET delivered_qty = EXCLUDED.delivered_qty;
  END IF;

  RETURN jsonb_build_object('status','success','message','Item updated');
END;
$function$;
