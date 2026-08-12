-- Fixes a real production defect: qvm_new_apps.quotations had no uniqueness constraint on
-- order_number, and create_quotation_with_items (the edge function backing both the internal RFQ
-- form and third-party integrations that supply their own order_number) created the parent
-- `quotations` row and its `quotation_items` rows via THREE separate, independently-committing
-- RPC calls (create_quotation, then a per-item get_estimated_price loop, then
-- create_quotation_items) with no wrapping transaction. Any failure between steps — a price
-- lookup error, a dropped connection, a race between two submissions generating/using the same
-- order_number — left a `quotations` row permanently committed with zero items. Confirmed live:
-- `SELECT order_number, count(*) FROM quotations GROUP BY order_number HAVING count(*) > 1`
-- returns zero rows on this environment, so the constraint below applies cleanly with no existing
-- duplicates to reconcile first.
--
-- Third-party integrations pass their own order_number directly (create_quotation_with_items/
-- index.ts:130-134: "Use provided order number if present, otherwise generate one") and, per
-- the business requirement, that value must never be allowed to collide with an existing order —
-- the UNIQUE constraint below is the actual enforcement of that, at the data layer, not just a
-- convention the caller is trusted to follow.

ALTER TABLE qvm_new_apps.quotations
  ADD CONSTRAINT quotations_order_number_key UNIQUE (order_number);

-- Single atomic replacement for the create_quotation -> get_estimated_price(*N) ->
-- create_quotation_items -> create_quotation_note call sequence the edge function used to make as
-- separate HTTP-level RPC calls. Everything here runs in one implicit transaction: if anything
-- raises (including the UNIQUE violation above, when a caller-supplied order_number is already
-- taken), the whole thing rolls back — the quotation row is never left orphaned without items.
-- Reuses the existing public.create_quotation_items/create_quotation_note/get_estimated_price
-- (nested plpgsql calls share the caller's transaction, unlike the edge function's separate HTTP
-- round trips) rather than re-implementing their logic (line_item_code numbering in particular).
CREATE FUNCTION qvm_new_apps.create_quotation_with_items(
  p_account_manager uuid,
  p_delivery_type integer,
  p_order_type integer,
  p_plate_number text,
  p_service_advisor uuid,
  p_client_id integer,
  p_region_id integer,
  p_customer_id bigint,
  p_items jsonb,
  p_insurance_company_id bigint DEFAULT NULL,
  p_order_number text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
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
    shipping_type, insurance_company_id
  ) VALUES (
    v_order_number, p_plate_number, p_order_type, p_delivery_type, p_service_advisor,
    p_account_manager, 'item', p_insurance_company_id
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

  IF p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN
    PERFORM public.create_quotation_note(v_quotation.quotation_id, p_notes, p_service_advisor);
  END IF;

  RETURN jsonb_build_object(
    'quotation_id', v_quotation.quotation_id,
    'order_number', v_quotation.order_number,
    'items', COALESCE(v_inserted_items, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.create_quotation_with_items(uuid, integer, integer, text, uuid, integer, integer, bigint, jsonb, bigint, text, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_quotation_with_items(uuid, integer, integer, text, uuid, integer, integer, bigint, jsonb, bigint, text, text) TO service_role;
