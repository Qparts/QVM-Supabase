-- The desk's alternative is shown to the workshop unless hidden.
--
-- A vendor's alternative starts hidden — the pricing team decides. The desk's own is the pricing
-- team's decision already, so it starts shown.
CREATE OR REPLACE FUNCTION qvm_new_apps.save_item_alternative(
  p_quotation_item_id bigint, p_part_number text, p_alternative_id bigint DEFAULT NULL,
  p_brand_class bigint DEFAULT NULL, p_brand_id bigint DEFAULT NULL, p_origin_country_id bigint DEFAULT NULL,
  p_note text DEFAULT NULL, p_photos jsonb DEFAULT NULL, p_visible_to_workshop boolean DEFAULT NULL,
  p_unit_price numeric DEFAULT NULL, p_available_quantity integer DEFAULT NULL, p_delivery_days integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE v_id bigint; v_origin bigint := p_origin_country_id;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Only the Qparts team edits alternatives here'; END IF;
  IF COALESCE(btrim(p_part_number), '') = '' THEN RAISE EXCEPTION 'An alternative needs a part number'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id) THEN
    RAISE EXCEPTION 'Unknown line';
  END IF;
  IF qvm_new_apps.is_genuine_class(p_brand_class) THEN v_origin := qvm_new_apps.genuine_origin_id(); END IF;

  IF p_alternative_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
      (cost_id, quotation_item_id, source, part_number, brand_class, brand_id, origin_country_id,
       unit_price, available_quantity, delivery_days, note, photos, visible_to_workshop, created_by)
    VALUES (NULL, p_quotation_item_id, 'qparts', btrim(p_part_number), p_brand_class, p_brand_id, v_origin,
            p_unit_price, p_available_quantity, p_delivery_days,
            -- The desk adds an alternative to offer it: shown to the workshop unless it says otherwise.
            NULLIF(btrim(COALESCE(p_note, '')), ''), COALESCE(p_photos, '[]'::jsonb), COALESCE(p_visible_to_workshop, true), auth.uid())
    RETURNING alternative_id INTO v_id;
  ELSE
    -- Any alternative on this line: the desk may correct a vendor's too. Its source stays.
    UPDATE qvm_new_apps.quotation_vendor_item_alternatives a
       SET part_number = btrim(p_part_number), brand_class = p_brand_class, brand_id = p_brand_id, origin_country_id = v_origin,
           unit_price = p_unit_price, available_quantity = p_available_quantity, delivery_days = p_delivery_days,
           note = NULLIF(btrim(COALESCE(p_note, '')), ''), photos = COALESCE(p_photos, a.photos),
           visible_to_workshop = COALESCE(p_visible_to_workshop, a.visible_to_workshop), updated_at = now()
     WHERE a.alternative_id = p_alternative_id AND a.quotation_item_id = p_quotation_item_id
    RETURNING a.alternative_id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'That alternative is not on this line'; END IF;
  END IF;
  RETURN jsonb_build_object('status', 'success', 'alternative_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 31 $$;
