-- Synced from QVM/test branch applied migration history (version 20260324112327, name: qpd351_delivery_note_rpcs)
-- QPD-351: Delivery Note RPCs
-- 1) get_delivery_note_detail
-- 2) update_delivery_note_item_inline
-- 3) update_delivery_note_header_inline
-- 4) finalize_delivery_note

CREATE OR REPLACE FUNCTION public.get_delivery_note_detail(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_delivery_id int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_delivery_id int;
  v_result jsonb;
BEGIN
  SELECT user_type INTO v_user_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Pick the delivery_id if passed, otherwise the most recent for this confirmed order
  SELECT d.delivery_id
  INTO v_delivery_id
  FROM qvm_new_apps.deliveries d
  WHERE d.confirmed_order_id = p_confirmed_order_id
  ORDER BY d.delivery_date DESC NULLS LAST, d.delivery_id DESC
  LIMIT 1;

  IF p_delivery_id IS NOT NULL THEN
    v_delivery_id := p_delivery_id;
  END IF;

  WITH co AS (
    SELECT co.confirmed_order_id, q.quotation_id, q.order_number
    FROM qvm_new_apps.confirmed_orders co
    LEFT JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    WHERE co.confirmed_order_id = p_confirmed_order_id
  ),
  header AS (
    SELECT
      co.confirmed_order_id,
      co.order_number,
      d.delivery_id,
      d.shipping_price,
      d.shipping_cost,
      (SELECT po.payment_account FROM qvm_new_apps.purchase_orders po WHERE po.confirmed_order_id = co.confirmed_order_id LIMIT 1) AS payment_account
    FROM co
    LEFT JOIN qvm_new_apps.deliveries d ON d.delivery_id = v_delivery_id
  ),
  items AS (
    SELECT
      qi.quotation_item_id,
      ci.confirmed_item_id,
      qi.part_description,
      ci.final_part_number,
      ci.final_brand_class,
      qi.brand_class,
      qi.price_before_vat,
      COALESCE(di.delivered_qty, ci.approved_qty, qi.quantity) AS delivered_qty,
      COALESCE(ci.item_status, qi.item_status) AS item_status_id,
      ls_status.list_data AS item_status,
      qi.part_number,
      qi.quantity AS requested_qty,
      ci.approved_qty
    FROM qvm_new_apps.confirmed_items ci
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.delivery_items di ON di.confirmed_item_id = ci.confirmed_item_id AND di.delivery_id = v_delivery_id
    LEFT JOIN qvm_new_apps.list_data ls_status ON ls_status.list_data_id = COALESCE(ci.item_status, qi.item_status)
    WHERE ci.confirmed_order_id = p_confirmed_order_id
  )
  SELECT jsonb_build_object(
    'status','success',
    'message','Delivery note detail fetched',
    'header', COALESCE((SELECT to_jsonb(h) FROM header h), '{}'::jsonb),
    'items', COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM items i), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_delivery_note_detail(uuid, int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_delivery_note_detail(uuid, int, int) TO authenticated;

-- Inline item updates: part_description (quotation_items), final_part_number/final_brand_class (confirmed_items), delivered_qty (delivery_items), price_before_vat (quotation_items)
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

REVOKE EXECUTE ON FUNCTION public.update_delivery_note_item_inline(uuid, int, text, text, int, int, numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_delivery_note_item_inline(uuid, int, text, text, int, int, numeric) TO authenticated;

-- Header updates: shipping_price, shipping_cost (deliveries), payment_account (purchase_orders)
CREATE OR REPLACE FUNCTION public.update_delivery_note_header_inline(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_shipping_price numeric DEFAULT NULL,
  p_shipping_cost numeric DEFAULT NULL,
  p_payment_account bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_delivery_id int;
BEGIN
  SELECT user_type INTO v_user_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Ensure a delivery row exists
  SELECT d.delivery_id INTO v_delivery_id FROM qvm_new_apps.deliveries d WHERE d.confirmed_order_id = p_confirmed_order_id ORDER BY d.delivery_id DESC LIMIT 1;
  IF v_delivery_id IS NULL THEN
    INSERT INTO qvm_new_apps.deliveries(confirmed_order_id) VALUES (p_confirmed_order_id) RETURNING delivery_id INTO v_delivery_id;
  END IF;

  IF p_shipping_price IS NOT NULL THEN
    UPDATE qvm_new_apps.deliveries SET shipping_price = p_shipping_price WHERE delivery_id = v_delivery_id;
  END IF;
  IF p_shipping_cost IS NOT NULL THEN
    UPDATE qvm_new_apps.deliveries SET shipping_cost = p_shipping_cost WHERE delivery_id = v_delivery_id;
  END IF;
  IF p_payment_account IS NOT NULL THEN
    UPDATE qvm_new_apps.purchase_orders SET payment_account = p_payment_account WHERE confirmed_order_id = p_confirmed_order_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Header updated', 'delivery_id', v_delivery_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_delivery_note_header_inline(uuid, int, numeric, numeric, bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_delivery_note_header_inline(uuid, int, numeric, numeric, bigint) TO authenticated;

-- Finalize: set DN Sign Pending (213), log status_logs, set delivery_date if null
CREATE OR REPLACE FUNCTION public.finalize_delivery_note(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_delivery_id int DEFAULT NULL,
  p_pdf_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_delivery_id int;
BEGIN
  SELECT user_type INTO v_user_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Resolve delivery_id
  IF p_delivery_id IS NOT NULL THEN
    v_delivery_id := p_delivery_id;
  ELSE
    SELECT d.delivery_id INTO v_delivery_id FROM qvm_new_apps.deliveries d WHERE d.confirmed_order_id = p_confirmed_order_id ORDER BY d.delivery_date DESC NULLS LAST, d.delivery_id DESC LIMIT 1;
  END IF;

  -- Update statuses to DN Sign Pending = 213 and log
  UPDATE qvm_new_apps.confirmed_items SET item_status = 213 WHERE confirmed_order_id = p_confirmed_order_id;
  INSERT INTO qvm_new_apps.status_logs(quotation_item_id, confirmed_item_id, item_status, status_changed_by)
  SELECT ci.quotation_item_id, ci.confirmed_item_id, 213, p_user_id
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_order_id = p_confirmed_order_id;

  -- Set delivery_date if null
  UPDATE qvm_new_apps.deliveries SET delivery_date = COALESCE(delivery_date, now()) WHERE delivery_id = v_delivery_id;

  RETURN jsonb_build_object('status','success','message','Delivery Note finalized','delivery_id', v_delivery_id,'pdf_url', p_pdf_url);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.finalize_delivery_note(uuid, int, int, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.finalize_delivery_note(uuid, int, int, text) TO authenticated;;
