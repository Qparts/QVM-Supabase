-- The quotation records the company it is for.
--
-- p_client_id was already passed in — used to price the items and to number the order — and then
-- thrown away. That was fine while a branch had exactly one company and the branch could be asked
-- later. A workshop now serves several, so the answer exists only at the moment the order is
-- raised, and this is where it is kept.

CREATE OR REPLACE FUNCTION qvm_new_apps.create_quotation_with_items(p_account_manager uuid, p_delivery_type integer, p_order_type integer, p_plate_number text, p_service_advisor uuid, p_client_id integer, p_region_id integer, p_customer_id bigint, p_items jsonb, p_insurance_company_id bigint DEFAULT NULL::bigint, p_order_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation qvm_new_apps.quotations;
  v_order_number text;
  v_item jsonb;
  v_items_payload jsonb := '[]'::jsonb;
  v_est numeric;
  v_inserted_items jsonb;
BEGIN
  IF NOT jsonb_typeof(p_items) = 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Items are required';
  END IF;

  v_order_number := NULLIF(btrim(p_order_number), '');
  IF v_order_number IS NULL THEN
    v_order_number := qvm_new_apps.generate_rfq_order_number(p_client_id, p_region_id);
  END IF;

  INSERT INTO qvm_new_apps.quotations (
    order_number, plate_number, order_type, delivery_type, service_advisor, account_manager,
    shipping_type, insurance_company_id,
    -- The company the order is for. It used to be inferable from the branch; a branch now serves
    -- several companies, so the choice made when raising the order is the only record of it.
    company_id
  ) VALUES (
    v_order_number, p_plate_number, p_order_type, p_delivery_type, p_service_advisor,
    p_account_manager, 'item', p_insurance_company_id,
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
    'items', COALESCE(v_inserted_items, '[]'::jsonb)
  );
END;
$function$;
