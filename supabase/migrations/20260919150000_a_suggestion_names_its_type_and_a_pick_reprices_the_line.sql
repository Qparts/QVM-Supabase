-- A vendor's suggestion names its type, and the workshop's pick reprices the line.
--
-- Two things. add_quotation_item_by_vendor refuses a suggestion with no brand class: the type is what
-- the pricing team and the workshop judge it by. And when the workshop picks an alternative (or the
-- original again), the line's prices follow: wholesale becomes the picked part's after-discount price,
-- the customer price keeps the line's margin, تسعيرك on the pricing page shows the new figures, and
-- the open request's snapshot is updated so the approval is of the price actually chosen.
CREATE OR REPLACE FUNCTION public.add_quotation_item_by_vendor(
  p_quotation_id int, p_part_number text DEFAULT NULL, p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1, p_brand_class int DEFAULT NULL, p_cost numeric DEFAULT NULL, p_note text DEFAULT NULL,
  p_agency_price numeric DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid(); v_vendor bigint; v_utype text; v_qv_id bigint;
  v_status_added int; v_order_number text; v_next_index int; v_line_item_code text; v_item_id bigint;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','error','message','Not authenticated'); END IF;
  SELECT ud.user_vendor, ud.user_type::text INTO v_vendor, v_utype FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_user;
  IF v_vendor IS NULL OR v_utype <> '205' THEN RETURN jsonb_build_object('status','error','message','Only vendor users can add items'); END IF;
  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;
  IF v_order_number IS NULL THEN RETURN jsonb_build_object('status','error','message','Invalid quotation_id'); END IF;
  -- The type (brand class) is what the pricing team and the workshop judge the suggestion by; a
  -- suggestion without one is not reviewable.
  IF p_brand_class IS NULL OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = p_brand_class) THEN
    RETURN jsonb_build_object('status','error','message','Pick the item type');
  END IF;

  SELECT quotation_vendor_id INTO v_qv_id FROM qvm_new_apps.quotation_vendors
  WHERE quotation_id = p_quotation_id AND vendor_id = v_vendor LIMIT 1;
  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
    VALUES (v_vendor, p_quotation_id, now()) RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  SELECT list_data_id INTO v_status_added FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(line_item_code,''),'^.*-([0-9]+)$','\1'),'')::int),0) + 1
  INTO v_next_index FROM qvm_new_apps.quotation_items WHERE quotation_id = p_quotation_id;
  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id, part_description, part_number, quantity, brand_class,
    item_status, created_by, created_at, updated_at, line_item_code
  ) VALUES (
    p_quotation_id, NULLIF(p_part_description,''), NULLIF(p_part_number,''),
    COALESCE(p_quantity,1), p_brand_class, v_status_added, v_user, now(), now(), v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  -- The two prices the vendor's own grid works in: cost is the price after discount (سعر الجملة),
  -- agency_price the price before it (سعر العميل), and the discount is derived, never typed.
  INSERT INTO qvm_new_apps.quotation_vendor_items (
    quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost, agency_price, discount_percent,
    from_database, vendor_item_status, created_at, updated_at
  ) VALUES (
    v_item_id, v_vendor, v_qv_id, false, p_cost, p_agency_price,
    CASE WHEN COALESCE(p_agency_price, 0) > 0 AND p_cost IS NOT NULL
         THEN round(((p_agency_price - p_cost) / p_agency_price) * 100, 2) END,
    false, NULL, now(), now());

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(p_note_type := 'quotation_items', p_type_id := v_item_id,
        p_note_description := p_note, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','quotation_item_id', v_item_id, 'line_item_code', v_line_item_code);
END; $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_pick_alternative(
  p_quotation_item_id bigint, p_alternative_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_qid   bigint;
  v_cost  bigint;
  v_part  text;
  v_class bigint;
  v_wholesale numeric;
  v_customer  numeric;
  v_ratio     numeric;
BEGIN
  SELECT qi.quotation_id INTO v_qid FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_qid IS NULL THEN RAISE EXCEPTION 'Unknown line'; END IF;

  IF NOT (qvm_new_apps.is_qparts_team()
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(v_qid))) THEN
    RAISE EXCEPTION 'Not allowed to choose for this order';
  END IF;

  IF p_alternative_id IS NOT NULL THEN
    -- The option has to be one offered on this line, and one the workshop was shown.
    SELECT a.cost_id INTO v_cost
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      JOIN qvm_new_apps.quotation_vendor_items v ON v.cost_id = a.cost_id
     WHERE a.alternative_id = p_alternative_id
       AND v.quotation_item_id = p_quotation_item_id
       AND a.visible_to_workshop;
    IF v_cost IS NULL THEN RAISE EXCEPTION 'That option is not offered on this line'; END IF;
  ELSE
    -- Back to the original: on the line the order is priced from — the open request's, else the
    -- pricing team's pick, else the best offer.
    SELECT COALESCE(
      (SELECT ai.cost_id FROM qvm_new_apps.quotation_approval_items ai
         JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
        WHERE ai.quotation_item_id = p_quotation_item_id AND ar.audience = 'workshop' AND ar.status = 'pending'
        ORDER BY ai.approval_round_id DESC LIMIT 1),
      (SELECT qi.selected_cost_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id),
      (SELECT v.cost_id FROM qvm_new_apps.quotation_vendor_items v
        WHERE v.quotation_item_id = p_quotation_item_id AND v.cost IS NOT NULL AND v.cost > 0
        ORDER BY v.best_cost DESC, v.cost ASC LIMIT 1)) INTO v_cost;
    IF v_cost IS NULL THEN RETURN jsonb_build_object('status', 'success'); END IF;
  END IF;

  -- The vendor line carries the choice: the pricing page reads it, the PO is written from it.
  UPDATE qvm_new_apps.quotation_vendor_items
     SET chosen_alternative_id = p_alternative_id, updated_at = now()
   WHERE cost_id = v_cost;

  -- The line's prices follow the pick. Wholesale is the picked part's after-discount price — the
  -- alternative's, or the vendor line's again for the original. The customer price keeps the line's
  -- own margin: the ratio تسعيرك already held between customer and wholesale, else the vendor's
  -- before/after ratio, else none. Written to the line (what the pricing page's تسعيرك shows) and to
  -- the open request's snapshot, so the approval is of the price actually chosen.
  SELECT CASE WHEN p_alternative_id IS NOT NULL THEN a.unit_price ELSE v.cost END,
         COALESCE(NULLIF(qi.agency_price, 0) / NULLIF(qi.price_before_vat, 0),
                  NULLIF(v.agency_price, 0) / NULLIF(v.cost, 0))
    INTO v_wholesale, v_ratio
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotation_vendor_items v ON v.cost_id = v_cost
    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.alternative_id = p_alternative_id
   WHERE qi.quotation_item_id = p_quotation_item_id;
  IF v_wholesale IS NOT NULL AND v_wholesale > 0 THEN
    v_customer := CASE WHEN p_alternative_id IS NULL
                       THEN COALESCE((SELECT NULLIF(v.agency_price, 0) FROM qvm_new_apps.quotation_vendor_items v WHERE v.cost_id = v_cost),
                                     CASE WHEN v_ratio IS NOT NULL THEN round(v_wholesale * v_ratio, 2) END)
                       ELSE CASE WHEN v_ratio IS NOT NULL THEN round(v_wholesale * v_ratio, 2) END END;
    UPDATE qvm_new_apps.quotation_items
       SET price_before_vat = v_wholesale,
           agency_price = COALESCE(v_customer, agency_price),
           total_price_before_vat = v_wholesale * GREATEST(COALESCE(quantity, 1), 1),
           updated_at = now()
     WHERE quotation_item_id = p_quotation_item_id;
  END IF;

  -- The open request, when this line is in one, says the same — the choice and the prices.
  UPDATE qvm_new_apps.quotation_approval_items ai
     SET chosen_alternative_id = p_alternative_id,
         wholesale_price = COALESCE(v_wholesale, ai.wholesale_price),
         customer_price  = COALESCE(v_customer, ai.customer_price)
    FROM qvm_new_apps.quotation_approval_rounds ar
   WHERE ar.approval_round_id = ai.approval_round_id
     AND ai.quotation_item_id = p_quotation_item_id AND ai.cost_id = v_cost
     AND ar.audience = 'workshop' AND ar.status = 'pending';

  -- A line already confirmed but not yet ordered follows too; an ordered one is the PO's now.
  SELECT COALESCE(a.part_number, qi.alternative_part_number, qi.part_number), COALESCE(a.brand_class, qi.brand_class)
    INTO v_part, v_class
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives a ON a.alternative_id = p_alternative_id
   WHERE qi.quotation_item_id = p_quotation_item_id;
  UPDATE qvm_new_apps.confirmed_items ci
     SET final_part_number = v_part, final_brand_class = v_class, updated_at = now()
    FROM qvm_new_apps.quotation_items qi
   WHERE ci.quotation_item_id = p_quotation_item_id
     AND qi.quotation_item_id = ci.quotation_item_id AND qi.cost_id IS NULL;

  RETURN jsonb_build_object('status', 'success', 'cost_id', v_cost, 'chosen_alternative_id', p_alternative_id,
                            'wholesale_price', v_wholesale, 'customer_price', v_customer);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 19 $$;
