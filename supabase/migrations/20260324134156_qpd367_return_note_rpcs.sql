-- Synced from QVM/test branch applied migration history (version 20260324134156, name: qpd367_return_note_rpcs)
-- QPD-367: Return Note RPCs
-- 1) get_return_note
-- 2) update_return_note_header_inline

CREATE OR REPLACE FUNCTION public.get_return_note(
  p_order_number text,
  p_return_id int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_q quotations%ROWTYPE;
  v_co confirmed_orders%ROWTYPE;
  v_ret returns%ROWTYPE;
  v_client_name text;
  v_branch_name text;
  v_plate text;
  v_payment_account_id integer;
  v_payment_account_label text;
  v_items jsonb := '[]'::jsonb;
  v_row RECORD;
  v_subtotal numeric := 0;
  v_vat_rate numeric := 0.15;
  v_vat_total numeric := 0;
  v_shipping_fee numeric := 0;
  v_grand_total numeric := 0;
BEGIN
  -- Determine return row
  IF p_return_id IS NOT NULL THEN
    SELECT * INTO v_ret FROM returns WHERE return_id = p_return_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Return not found', 'data', NULL);
    END IF;

    SELECT * INTO v_co FROM confirmed_orders WHERE confirmed_order_id = v_ret.confirmed_order_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Confirmed order not found for this return', 'data', NULL);
    END IF;

    SELECT * INTO v_q FROM quotations WHERE quotation_id = v_co.quotation_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Quotation not found for this return', 'data', NULL);
    END IF;
  ELSE
    SELECT * INTO v_q FROM quotations WHERE order_number = p_order_number LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Order number not found', 'data', NULL);
    END IF;

    SELECT * INTO v_co
    FROM confirmed_orders
    WHERE quotation_id = v_q.quotation_id
    ORDER BY created_at DESC NULLS LAST
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'No confirmed order found for this order', 'data', NULL);
    END IF;

    SELECT * INTO v_ret
    FROM returns
    WHERE confirmed_order_id = v_co.confirmed_order_id
    ORDER BY return_date DESC NULLS LAST, created_at DESC NULLS LAST
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'No return found for this order', 'data', NULL);
    END IF;
  END IF;

  v_shipping_fee := COALESCE(v_ret.shipping_price, 0);

  -- Buyer (client + branch)
  SELECT cb.branch_name,
         ld_client.list_data AS client_name
    INTO v_branch_name, v_client_name
  FROM quotation_items qi
  LEFT JOIN client_branches cb ON cb.customer_id = qi.customer_id
  LEFT JOIN list_data ld_client ON ld_client.list_data_id = cb.list_data_id
  WHERE qi.quotation_id = v_q.quotation_id
  LIMIT 1;

  v_plate := v_q.plate_number;

  -- Payment account from latest purchase order for this confirmed order (if any)
  SELECT po.payment_account
    INTO v_payment_account_id
  FROM purchase_orders po
  WHERE po.confirmed_order_id = v_ret.confirmed_order_id
    AND po.payment_account IS NOT NULL
  ORDER BY po.created_at DESC
  LIMIT 1;

  IF v_payment_account_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_payment_account_label FROM list_data ld WHERE ld.list_data_id = v_payment_account_id;
  END IF;

  -- Items and totals
  FOR v_row IN
    SELECT
      ri.return_item_id,
      ri.return_qty,
      ci.confirmed_item_id,
      ci.final_part_number,
      ci.final_brand_class,
      qi.part_description,
      qi.part_number,
      qi.main_brand,
      qi.price_before_vat,
      qi.discount_percent
    FROM return_items ri
    JOIN confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
    JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE ri.return_id = v_ret.return_id
  LOOP
    DECLARE
      _unit_price numeric := COALESCE(v_row.price_before_vat, 0);
      _discount numeric := COALESCE(v_row.discount_percent, 0);
      _unit_after numeric := _unit_price * (1 - _discount);
      _qty numeric := COALESCE(v_row.return_qty, 0);
      _line_before numeric := _unit_after * _qty;
      _line_vat numeric := round(_line_before * v_vat_rate, 2);
      _line_after numeric := _line_before + _line_vat;
      _main_brand text;
      _final_brand_class text;
    BEGIN
      SELECT ld.list_data INTO _main_brand FROM list_data ld WHERE ld.list_data_id = v_row.main_brand;
      SELECT ld.list_data INTO _final_brand_class FROM list_data ld WHERE ld.list_data_id = v_row.final_brand_class;

      v_subtotal := v_subtotal + _line_before;
      v_vat_total := v_vat_total + _line_vat;

      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'return_item_id', v_row.return_item_id,
        'confirmed_item_id', v_row.confirmed_item_id,
        'part_description', COALESCE(v_row.part_description, ''),
        'final_part_number', COALESCE(v_row.final_part_number, v_row.part_number),
        'main_brand', COALESCE(_main_brand, NULL),
        'final_brand_class', COALESCE(_final_brand_class, NULL),
        'returned_qty', _qty,
        'unit_price_before_vat', _unit_price,
        'discount_percent', _discount,
        'unit_price_after_discount', _unit_after,
        'line_total_before_vat', _line_before,
        'vat_rate', v_vat_rate,
        'line_vat_amount', _line_vat,
        'line_total_after_vat', _line_after
      ));
    END;
  END LOOP;

  v_grand_total := v_subtotal + v_vat_total + COALESCE(v_shipping_fee, 0);

  RETURN jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'header', jsonb_build_object(
        'order_number', v_q.order_number,
        'order_date', v_co.created_at,
        'return_date', v_ret.return_date,
        'buyer', jsonb_build_object('client_name', COALESCE(v_client_name, ''), 'branch_name', COALESCE(v_branch_name, '')),
        'seller_name', 'Qparts',
        'plate_number', v_plate,
        'return_id', v_ret.return_id,
        'confirmed_order_id', v_ret.confirmed_order_id,
        'shipping_price', COALESCE(v_ret.shipping_price, 0),
        'shipping_cost', COALESCE(v_ret.shipping_cost, 0),
        'payment_account', CASE WHEN v_payment_account_id IS NOT NULL THEN jsonb_build_object('id', v_payment_account_id, 'label', COALESCE(v_payment_account_label, '')) ELSE NULL END,
        'po_reference', v_ret.referenced_client_po
      ),
      'items', v_items,
      'totals', jsonb_build_object(
        'subtotal_before_vat', v_subtotal,
        'vat_total', v_vat_total,
        'shipping_fee', COALESCE(v_shipping_fee, 0),
        'grand_total', v_grand_total
      )
    )
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_return_note(text, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_return_note(text, int) TO authenticated;

-- Inline header update for Return Note (shipping fields only)
CREATE OR REPLACE FUNCTION public.update_return_note_header_inline(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_return_id int DEFAULT NULL,
  p_shipping_price numeric DEFAULT NULL,
  p_shipping_cost numeric DEFAULT NULL
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
    UPDATE returns SET shipping_price = p_shipping_price WHERE return_id = v_return_id;
  END IF;
  IF p_shipping_cost IS NOT NULL THEN
    UPDATE returns SET shipping_cost = p_shipping_cost WHERE return_id = v_return_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Return header updated','return_id', v_return_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_return_note_header_inline(uuid, int, int, numeric, numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_return_note_header_inline(uuid, int, int, numeric, numeric) TO authenticated;
;
