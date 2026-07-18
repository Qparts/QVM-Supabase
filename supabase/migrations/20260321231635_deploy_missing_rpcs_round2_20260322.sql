-- Synced from QVM/test branch applied migration history (version 20260321231635, name: deploy_missing_rpcs_round2_20260322)
BEGIN;

-- public.get_delivery_note (from production)
CREATE OR REPLACE FUNCTION public.get_delivery_note(
  p_order_number text,
  p_delivery_id integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_q quotations%ROWTYPE;
  v_co confirmed_orders%ROWTYPE;
  v_del deliveries%ROWTYPE;
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
  -- Primary selection path
  IF p_delivery_id IS NOT NULL THEN
    -- Lookup delivery
    SELECT * INTO v_del FROM deliveries WHERE delivery_id = p_delivery_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Delivery not found', 'data', NULL);
    END IF;

    -- Lookup confirmed order
    SELECT * INTO v_co FROM confirmed_orders WHERE confirmed_order_id = v_del.confirmed_order_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Confirmed order not found for this delivery', 'data', NULL);
    END IF;

    -- Lookup quotation
    SELECT * INTO v_q FROM quotations WHERE quotation_id = v_co.quotation_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'Quotation not found for this delivery', 'data', NULL);
    END IF;
  ELSE
    -- Lookup by order number -> confirmed order -> latest delivery
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

    SELECT * INTO v_del
    FROM deliveries
    WHERE confirmed_order_id = v_co.confirmed_order_id
    ORDER BY delivery_date DESC NULLS LAST, created_at DESC NULLS LAST
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', false, 'message', 'No delivery found for this order', 'data', NULL);
    END IF;
  END IF;

  v_shipping_fee := COALESCE(v_del.shipping_price, 0);

  -- Buyer (client + branch) from any item of the quotation
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
  WHERE po.confirmed_order_id = v_del.confirmed_order_id
    AND po.payment_account IS NOT NULL
  ORDER BY po.created_at DESC
  LIMIT 1;

  IF v_payment_account_id IS NOT NULL THEN
    SELECT ld.list_data INTO v_payment_account_label FROM list_data ld WHERE ld.list_data_id = v_payment_account_id;
  END IF;

  -- Build items list and compute totals
  FOR v_row IN
    SELECT
      di.delivery_item_id,
      di.delivered_qty,
      ci.confirmed_item_id,
      ci.final_part_number,
      ci.final_brand_class,
      qi.part_description,
      qi.part_number,
      qi.main_brand,
      qi.price_before_vat,
      qi.discount_percent
    FROM delivery_items di
    JOIN confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
    JOIN quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE di.delivery_id = v_del.delivery_id
  LOOP
    DECLARE
      _unit_price numeric := COALESCE(v_row.price_before_vat, 0);
      _discount numeric := COALESCE(v_row.discount_percent, 0);
      _unit_after numeric := _unit_price * (1 - _discount);
      _qty numeric := COALESCE(v_row.delivered_qty, 0);
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
        'delivery_item_id', v_row.delivery_item_id,
        'confirmed_item_id', v_row.confirmed_item_id,
        'part_description', COALESCE(v_row.part_description, ''),
        'final_part_number', COALESCE(v_row.final_part_number, v_row.part_number),
        'main_brand', COALESCE(_main_brand, NULL),
        'final_brand_class', COALESCE(_final_brand_class, NULL),
        'delivered_qty', _qty,
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
        'delivery_date', v_del.delivery_date,
        'buyer', jsonb_build_object('client_name', COALESCE(v_client_name, ''), 'branch_name', COALESCE(v_branch_name, '')),
        'seller_name', 'Qparts',
        'plate_number', v_plate,
        'delivery_id', v_del.delivery_id,
        'confirmed_order_id', v_del.confirmed_order_id,
        'shipping_price', COALESCE(v_del.shipping_price, 0),
        'shipping_cost', COALESCE(v_del.shipping_cost, 0),
        'payment_account', CASE WHEN v_payment_account_id IS NOT NULL THEN jsonb_build_object('id', v_payment_account_id, 'label', COALESCE(v_payment_account_label, '')) ELSE NULL END
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
REVOKE EXECUTE ON FUNCTION public.get_delivery_note(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_delivery_note(text, integer) TO authenticated;

-- public.get_status_logs_by_order (from production)
CREATE OR REPLACE FUNCTION public.get_status_logs_by_order(
  p_order_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_q RECORD;
  v_submitter_name text;
  v_submitter_id uuid;
  v_initial_am uuid;
  v_initial_am_name text;
  v_managers jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
  v_item RECORD;
  v_timeline jsonb := '[]'::jsonb;
  v_row RECORD;
BEGIN
  SELECT q.* INTO v_q FROM quotations q WHERE q.order_number = p_order_number LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', false, 'message', 'No records found for this RFQ/Order number.', 'data', NULL);
  END IF;

  SELECT ud.user_id, ud.user_name
    INTO v_submitter_id, v_submitter_name
  FROM user_data ud WHERE ud.user_id = v_q.service_advisor;

  v_initial_am := v_q.account_manager;
  SELECT ud.user_name INTO v_initial_am_name FROM user_data ud WHERE ud.user_id = v_initial_am;

  IF v_initial_am IS NOT NULL THEN
    v_managers := v_managers || jsonb_build_array(
      jsonb_build_object(
        'user_id', v_initial_am,
        'user_name', COALESCE(v_initial_am_name, ''),
        'assigned_at', v_q.created_at
      )
    );
  END IF;

  FOR v_row IN
    SELECT qa.created_at, qa.assigned_from, qa.assigned_to
    FROM quotation_account_managers qa
    WHERE qa.quotation_id = v_q.quotation_id
    ORDER BY qa.created_at ASC
  LOOP
    IF v_row.assigned_from IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_managers) e WHERE (e->>'user_id')::uuid = v_row.assigned_from
    ) THEN
      v_managers := v_managers || jsonb_build_array(
        jsonb_build_object(
          'user_id', v_row.assigned_from,
          'user_name', COALESCE((SELECT u.user_name FROM user_data u WHERE u.user_id = v_row.assigned_from), ''),
          'assigned_at', v_row.created_at
        )
      );
    END IF;

    IF v_row.assigned_to IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_managers) e WHERE (e->>'user_id')::uuid = v_row.assigned_to
    ) THEN
      v_managers := v_managers || jsonb_build_array(
        jsonb_build_object(
          'user_id', v_row.assigned_to,
          'user_name', COALESCE((SELECT u.user_name FROM user_data u WHERE u.user_id = v_row.assigned_to), ''),
          'assigned_at', v_row.created_at
        )
      );
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT qi.quotation_item_id, qi.part_description, qi.part_number, qi.item_status
    FROM quotation_items qi
    WHERE qi.quotation_id = v_q.quotation_id
    ORDER BY qi.quotation_item_id ASC
  LOOP
    v_timeline := '[]'::jsonb;

    FOR v_row IN
      SELECT sl.item_status, ld.list_data AS status_name, sl.created_at, sl.status_changed_by
      FROM status_logs sl
      LEFT JOIN list_data ld ON ld.list_data_id = sl.item_status
      WHERE sl.quotation_item_id = v_item.quotation_item_id
      ORDER BY sl.created_at ASC
    LOOP
      v_timeline := v_timeline || jsonb_build_array(
        jsonb_build_object(
          'status_id', v_row.item_status,
          'status_name', v_row.status_name,
          'timestamp', v_row.created_at,
          'logged_by', jsonb_build_object(
            'user_id', v_row.status_changed_by,
            'user_name', COALESCE((SELECT u.user_name FROM user_data u WHERE u.user_id = v_row.status_changed_by), '')
          )
        )
      );
    END LOOP;

    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'quotation_item_id', v_item.quotation_item_id,
        'title', concat_ws(' - ', COALESCE(v_item.part_description, ''), COALESCE(v_item.part_number, '')),
        'current_status_id', CASE
          WHEN jsonb_array_length(v_timeline) > 0 THEN ((v_timeline->-1)->>'status_id')::int
          ELSE v_item.item_status
        END,
        'current_status', CASE
          WHEN jsonb_array_length(v_timeline) > 0 THEN (v_timeline->-1)->>'status_name'
          ELSE (SELECT ld.list_data FROM list_data ld WHERE ld.list_data_id = v_item.item_status)
        END,
        'timeline', v_timeline
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'metadata', jsonb_build_object(
        'order_number', v_q.order_number,
        'rfq_submitter', jsonb_build_object('user_id', v_submitter_id, 'user_name', COALESCE(v_submitter_name, '')),
        'rfq_submission_date', v_q.created_at,
        'initial_account_manager', jsonb_build_object('user_id', v_initial_am, 'user_name', COALESCE(v_initial_am_name, '')),
        'account_managers_sequence', v_managers
      ),
      'items', v_items
    )
  );
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_status_logs_by_order(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_status_logs_by_order(text) TO authenticated;

-- public.nextval wrapper for qvm_new_apps.nextval(text)
CREATE OR REPLACE FUNCTION public.nextval(seqname text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','qvm_new_apps'
AS $$
  SELECT qvm_new_apps.nextval(seqname);
$$;
REVOKE EXECUTE ON FUNCTION public.nextval(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.nextval(text) TO authenticated;

COMMIT;;
