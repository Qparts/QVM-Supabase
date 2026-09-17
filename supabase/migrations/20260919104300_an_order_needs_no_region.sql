-- An order needs no region.
--
-- The RFQ form asked for a region nobody used: the order took its region from the branch, and the
-- only thing the region ever did was pick the order-number sequence. Now a branch without a region
-- is not a refused order — the number is drawn under the region the company already numbers in,
-- else Riyadh, and the sequence is created on demand. The edge function stops requiring one.
CREATE OR REPLACE FUNCTION qvm_new_apps.create_quotation_with_items(p_account_manager uuid, p_delivery_type integer, p_order_type integer, p_plate_number text, p_service_advisor uuid, p_client_id integer, p_region_id integer, p_customer_id bigint, p_items jsonb, p_insurance_company_id bigint, p_order_number text, p_notes text, p_request_kind text DEFAULT 'purchase'::text, p_customer_address_id bigint DEFAULT NULL::bigint, p_end_customer_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_number_region integer;
  v_quotation qvm_new_apps.quotations;
  v_order_number text;
  v_item jsonb;
  v_items_payload jsonb := '[]'::jsonb;
  v_est numeric;
  v_inserted_items jsonb;
  v_kind text;
  v_addr bigint;
BEGIN
  IF NOT jsonb_typeof(p_items) = 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Items are required';
  END IF;

  v_kind := lower(nullif(btrim(coalesce(p_request_kind, '')), ''));
  IF v_kind IS NULL THEN v_kind := 'purchase'; END IF;
  IF v_kind NOT IN ('quote', 'purchase') THEN
    RAISE EXCEPTION 'نوع الطلب غير معروف: %', p_request_kind;
  END IF;

  -- «عرض سعر» is only on offer to a customer whose approvals are switched on:
  -- the priced offer has to route through someone, and with approvals off
  -- there is nobody to route it to.
  IF v_kind = 'quote' AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.customers c
        WHERE c.list_data_id = p_client_id AND c.approvals_enabled AND c.merged_into IS NULL) THEN
    RAISE EXCEPTION 'هذا العميل لا تُفعَّل عنده الاعتمادات، فلا يمكن إنشاء «عرض سعر»';
  END IF;

  -- An address switched off, not meant to receive orders, or belonging somewhere else is not an
  -- address this order can be sent to.
  --
  -- Ownership is checked against the BRANCH the order is being raised on. It used to be checked
  -- against the company, through customer_addresses.customer_id -> customers.list_data_id, which
  -- was right while a branch belonged to exactly one company. It is not right now: a branch owns
  -- its addresses, a workshop serves several companies, and an address created from the client
  -- tree has customer_id NULL whenever the branch's company has no customers row — so the company
  -- join would refuse an address the order form had just offered. The company form is kept for the
  -- addresses that genuinely are a company's.
  IF p_customer_address_id IS NOT NULL THEN
    SELECT a.address_id INTO v_addr
      FROM qvm_new_apps.customer_addresses a
     WHERE a.address_id = p_customer_address_id
       AND a.is_active
       AND a.receives_orders
       AND (
             a.client_branch_id = p_customer_id
             OR (a.client_branch_id IS NULL AND EXISTS (
                   SELECT 1 FROM qvm_new_apps.customers c
                    WHERE c.customer_id = a.customer_id AND c.list_data_id = p_client_id))
           );
    IF v_addr IS NULL THEN
      RAISE EXCEPTION 'العنوان المختار لا يخص هذا الفرع أو لا يستقبل طلبات';
    END IF;
  END IF;

  v_order_number := NULLIF(btrim(p_order_number), '');
  IF v_order_number IS NULL THEN
    -- The region only ever served the order number, whose sequences are keyed by (company, region).
    -- A branch with no region still gets a number: under the region the company already numbers
    -- in, else Riyadh, with the sequence created on demand — never a refusal.
    v_number_region := p_region_id;
    IF v_number_region IS NULL THEN
      SELECT ons.region_id INTO v_number_region
        FROM qvm_new_apps.order_number_sequences ons
       WHERE ons.lists_data_id = p_client_id
       ORDER BY ons.sequence_id LIMIT 1;
      v_number_region := COALESCE(v_number_region, 13);
      PERFORM qvm_new_apps.ensure_order_number_sequence(p_client_id, v_number_region);
    END IF;
    v_order_number := qvm_new_apps.generate_rfq_order_number(p_client_id, v_number_region);
  END IF;

  INSERT INTO qvm_new_apps.quotations (
    order_number, plate_number, order_type, delivery_type, service_advisor, account_manager,
    shipping_type, insurance_company_id, request_kind, customer_address_id, end_customer_id,
    -- The company the order is for. It used to be inferable from the branch; a branch now serves
    -- several companies, so the choice made when raising the order is the only record of it.
    company_id
  ) VALUES (
    v_order_number, p_plate_number, p_order_type, p_delivery_type, p_service_advisor,
    p_account_manager, 'item', p_insurance_company_id, v_kind, v_addr, p_end_customer_id,
    p_client_id
  ) RETURNING * INTO v_quotation;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_est := public.get_estimated_price(
      p_client_id := p_client_id,
      p_part_number := v_item->>'part_number',
      p_brand_class_id := (v_item->>'brand_class')::integer
    );
    v_items_payload := v_items_payload || jsonb_build_object(
      'quotation_id', v_quotation.quotation_id,
      'customer_id', p_customer_id,
      'vin', v_item->'vin',
      'main_brand', v_item->'main_brand',
      'model', v_item->'model',
      'part_number', v_item->'part_number',
      'part_description', v_item->'part_description',
      'quantity', v_item->'quantity',
      'brand_class', v_item->'brand_class',
      'part_photo', v_item->'part_photo',
      'item_status', CASE WHEN COALESCE(v_item->>'part_number', '') <> '' THEN 235 ELSE 236 END,
      'item_PK', v_item->'item_PK',
      'estimated_price', v_est
    );
  END LOOP;

  SELECT jsonb_agg(to_jsonb(t)) INTO v_inserted_items
  FROM public.create_quotation_items(v_items_payload) t;

  -- Inserted directly rather than via public.create_quotation_note: that function now requires
  -- auth.uid() (20260812100000_notes_rpc_authorization.sql, closing a real hole where it used to
  -- trust a caller-supplied p_user_id with no check at all). But this whole function is called by
  -- the create_quotation_with_items EDGE FUNCTION using the service-role client, not the end
  -- user's own session — auth.uid() is NULL in that context even though the edge function already
  -- independently verified the real user via auth.getUser(jwt) and passed that identity along as
  -- p_service_advisor. This is already a trusted, pre-authenticated context (reachable only
  -- through that edge function), so it's safe to write the note directly with p_service_advisor
  -- rather than route through the externally-facing, auth.uid()-checked wrapper.
  IF p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN
    INSERT INTO qvm_new_apps.notes (type_id, note_type, note_description, user_id, created_at)
    VALUES (v_quotation.quotation_id, 'quotations', p_notes, p_service_advisor, now());
  END IF;

  RETURN jsonb_build_object(
    'quotation_id', v_quotation.quotation_id,
    'order_number', v_quotation.order_number,
    'request_kind', v_quotation.request_kind,
    'customer_address_id', v_quotation.customer_address_id,
    'end_customer_id', v_quotation.end_customer_id,
    'items', COALESCE(v_inserted_items, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 17 $$;
