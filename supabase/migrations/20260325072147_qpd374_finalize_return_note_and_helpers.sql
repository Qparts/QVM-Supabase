-- Synced from QVM/test branch applied migration history (version 20260325072147, name: qpd374_finalize_return_note_and_helpers)
-- QPD-374: Finalize Return Note and helper to get order number by confirmed order
SET search_path TO qvm_new_apps, public;

-- Helper: get order number by confirmed order id
CREATE OR REPLACE FUNCTION public.get_order_number_by_confirmed_order(
  p_confirmed_order_id int
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_order_number text;
BEGIN
  SELECT q.order_number INTO v_order_number
  FROM confirmed_orders co
  JOIN quotations q ON q.quotation_id = co.quotation_id
  WHERE co.confirmed_order_id = p_confirmed_order_id
  LIMIT 1;

  RETURN v_order_number;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_order_number_by_confirmed_order(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_order_number_by_confirmed_order(int) TO authenticated;

-- Finalize Return Note: set statuses to RN Sign Pending and log
CREATE OR REPLACE FUNCTION public.finalize_return_note(
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
  v_status_id int := 214; -- RN Sign Pending
  v_po_id bigint;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Ensure return exists
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

  -- Persist header edits if provided
  IF p_shipping_price IS NOT NULL THEN
    UPDATE returns SET shipping_price = p_shipping_price, updated_at = now() WHERE return_id = v_return_id;
  END IF;
  IF p_shipping_cost IS NOT NULL THEN
    UPDATE returns SET shipping_cost = p_shipping_cost, updated_at = now() WHERE return_id = v_return_id;
  END IF;
  IF p_payment_account IS NOT NULL THEN
    SELECT po_id INTO v_po_id FROM purchase_orders WHERE confirmed_order_id = p_confirmed_order_id ORDER BY created_at DESC LIMIT 1;
    IF v_po_id IS NULL THEN
      INSERT INTO purchase_orders(confirmed_order_id, payment_account) VALUES (p_confirmed_order_id, p_payment_account)
      RETURNING po_id INTO v_po_id;
    ELSE
      UPDATE purchase_orders SET payment_account = p_payment_account WHERE po_id = v_po_id;
    END IF;
  END IF;

  -- Update statuses for all items in this return
  UPDATE confirmed_items ci
  SET item_status = v_status_id
  WHERE ci.confirmed_item_id IN (
    SELECT ri.confirmed_item_id
    FROM return_items ri
    WHERE ri.return_id = v_return_id
  );

  -- Log status changes
  INSERT INTO status_logs(quotation_item_id, confirmed_item_id, item_status, status_changed_by)
  SELECT ci.quotation_item_id, ci.confirmed_item_id, v_status_id, p_user_id
  FROM confirmed_items ci
  WHERE ci.confirmed_item_id IN (
    SELECT ri.confirmed_item_id
    FROM return_items ri
    WHERE ri.return_id = v_return_id
  );

  RETURN jsonb_build_object('status','success','message','Return note finalized','return_id', v_return_id, 'new_status_id', v_status_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.finalize_return_note(uuid, int, int, numeric, numeric, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.finalize_return_note(uuid, int, int, numeric, numeric, int) TO authenticated;;
