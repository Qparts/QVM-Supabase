-- Synced from QVM/test branch applied migration history (version 20260325071655, name: qpd374_return_note_editing_rpcs_and_indexes)
-- QPD-374: Return Note Editing - constraints and RPCs
SET search_path TO qvm_new_apps, public;

-- 1) Ensure unique pairing return_items(return_id, confirmed_item_id) for safe upserts
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'qvm_new_apps'
      AND tablename = 'return_items'
      AND indexname = 'ux_return_items_return_confirmed'
  ) THEN
    CREATE UNIQUE INDEX ux_return_items_return_confirmed
      ON qvm_new_apps.return_items (return_id, confirmed_item_id);
  END IF;
END $$;

-- 2) Update header RPC: include payment account update
CREATE OR REPLACE FUNCTION public.update_return_note_header_inline(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_return_id int DEFAULT NULL,
  p_shipping_price numeric DEFAULT NULL,
  p_shipping_cost numeric DEFAULT NULL,
  p_payment_account int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_return_id int;
  v_po_id bigint;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  IF p_return_id IS NOT NULL THEN
    v_return_id := p_return_id;
  ELSE
    SELECT r.return_id INTO v_return_id
    FROM returns r
    WHERE r.confirmed_order_id = p_confirmed_order_id
    ORDER BY r.return_date DESC NULLS LAST, r.created_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_return_id IS NULL THEN
    INSERT INTO returns(confirmed_order_id) VALUES (p_confirmed_order_id) RETURNING return_id INTO v_return_id;
  END IF;

  IF p_shipping_price IS NOT NULL THEN
    UPDATE returns SET shipping_price = p_shipping_price, updated_at = now() WHERE return_id = v_return_id;
  END IF;
  IF p_shipping_cost IS NOT NULL THEN
    UPDATE returns SET shipping_cost = p_shipping_cost, updated_at = now() WHERE return_id = v_return_id;
  END IF;

  IF p_payment_account IS NOT NULL THEN
    -- Update existing purchase order payment account or insert minimal row
    SELECT po_id INTO v_po_id FROM purchase_orders WHERE confirmed_order_id = p_confirmed_order_id ORDER BY created_at DESC LIMIT 1;
    IF v_po_id IS NULL THEN
      INSERT INTO purchase_orders(confirmed_order_id, payment_account) VALUES (p_confirmed_order_id, p_payment_account)
      RETURNING po_id INTO v_po_id;
    ELSE
      UPDATE purchase_orders SET payment_account = p_payment_account WHERE po_id = v_po_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('status','success','message','Return header updated','return_id', v_return_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_return_note_header_inline(uuid, int, int, numeric, numeric, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_return_note_header_inline(uuid, int, int, numeric, numeric, int) TO authenticated;

-- 3) Item-level inline update RPC
CREATE OR REPLACE FUNCTION public.update_return_note_item_inline(
  p_user_id uuid,
  p_confirmed_item_id int,
  p_part_description text DEFAULT NULL,
  p_final_part_number text DEFAULT NULL,
  p_final_brand_class int DEFAULT NULL,
  p_return_qty int DEFAULT NULL,
  p_return_id int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_qi_id int;
  v_co_id int;
  v_return_id int;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Map confirmed item → quotation item and confirmed order
  SELECT ci.quotation_item_id, ci.confirmed_order_id
    INTO v_qi_id, v_co_id
  FROM confirmed_items ci
  WHERE ci.confirmed_item_id = p_confirmed_item_id;

  IF v_qi_id IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Confirmed item not found');
  END IF;

  -- Update quotation_items (part description)
  IF p_part_description IS NOT NULL THEN
    UPDATE quotation_items SET part_description = p_part_description WHERE quotation_item_id = v_qi_id;
  END IF;

  -- Update confirmed_items (final part number, final brand class)
  IF p_final_part_number IS NOT NULL THEN
    UPDATE confirmed_items SET final_part_number = p_final_part_number WHERE confirmed_item_id = p_confirmed_item_id;
  END IF;
  IF p_final_brand_class IS NOT NULL THEN
    UPDATE confirmed_items SET final_brand_class = p_final_brand_class WHERE confirmed_item_id = p_confirmed_item_id;
  END IF;

  -- Ensure a returns row exists and upsert returned qty
  IF p_return_id IS NOT NULL THEN
    v_return_id := p_return_id;
  ELSE
    SELECT r.return_id INTO v_return_id
    FROM returns r
    WHERE r.confirmed_order_id = v_co_id
    ORDER BY r.return_date DESC NULLS LAST, r.created_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_return_id IS NULL THEN
    INSERT INTO returns(confirmed_order_id) VALUES (v_co_id) RETURNING return_id INTO v_return_id;
  END IF;

  IF p_return_qty IS NOT NULL THEN
    INSERT INTO return_items(return_id, confirmed_item_id, return_qty)
    VALUES (v_return_id, p_confirmed_item_id, p_return_qty)
    ON CONFLICT (return_id, confirmed_item_id)
    DO UPDATE SET return_qty = EXCLUDED.return_qty, updated_at = now();
  END IF;

  RETURN jsonb_build_object('status','success','message','Return item updated','return_id', v_return_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_return_note_item_inline(uuid, int, text, text, int, int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_return_note_item_inline(uuid, int, text, text, int, int, int) TO authenticated;
;
