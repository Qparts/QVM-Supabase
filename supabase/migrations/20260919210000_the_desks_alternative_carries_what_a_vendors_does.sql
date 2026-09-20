-- The desk's alternative carries what a vendor's does, and the desk may edit any.
--
-- One table, one form: an alternative added on the Extract PN page takes the same fields as a
-- vendor's — number, grade, brand, origin, price, quantity, delivery days, note, photos, shown or
-- not — and the Qparts team may edit any alternative on a line, whoever offered it (its source is
-- never changed; only the desk's own can be removed here).
DROP FUNCTION IF EXISTS public.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean);
DROP FUNCTION IF EXISTS qvm_new_apps.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean);

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
            NULLIF(btrim(COALESCE(p_note, '')), ''), COALESCE(p_photos, '[]'::jsonb), COALESCE(p_visible_to_workshop, false), auth.uid())
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

-- The list, in the shape the shared panel reads (origin names in both languages).
CREATE OR REPLACE FUNCTION qvm_new_apps.list_item_alternatives(p_quotation_item_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'alternative_id', a.alternative_id, 'source', a.source, 'cost_id', a.cost_id,
             'vendor_name', (SELECT v3.vendor_name FROM qvm_new_apps.quotation_vendor_items q3
                               JOIN qvm_new_apps.vendors v3 ON v3.vendor_id = q3.vendor_id WHERE q3.cost_id = a.cost_id),
             'part_number', a.part_number, 'brand_class', a.brand_class, 'brand_class_name', bc.list_data,
             'brand_id', a.brand_id, 'brand_name', br.list_data, 'origin_country_id', a.origin_country_id,
             'origin_country_name_en', oc.name_en, 'origin_country_name_ar', oc.name_ar,
             'origin', COALESCE(oc.name_ar, oc.name_en), 'unit_price', a.unit_price, 'available_quantity', a.available_quantity,
             'delivery_days', a.delivery_days, 'note', a.note, 'photos', a.photos, 'visible_to_workshop', a.visible_to_workshop,
             'created_at', a.created_at) ORDER BY a.source DESC, a.alternative_id)
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
      LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
      LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
     WHERE a.quotation_item_id = p_quotation_item_id), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.save_item_alternative(p_quotation_item_id bigint, p_part_number text, p_alternative_id bigint DEFAULT NULL, p_brand_class bigint DEFAULT NULL, p_brand_id bigint DEFAULT NULL, p_origin_country_id bigint DEFAULT NULL, p_note text DEFAULT NULL, p_photos jsonb DEFAULT NULL, p_visible_to_workshop boolean DEFAULT NULL, p_unit_price numeric DEFAULT NULL, p_available_quantity integer DEFAULT NULL, p_delivery_days integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.save_item_alternative(p_quotation_item_id, p_part_number, p_alternative_id, p_brand_class, p_brand_id, p_origin_country_id, p_note, p_photos, p_visible_to_workshop, p_unit_price, p_available_quantity, p_delivery_days) $$;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean, numeric, integer, integer)',
    'qvm_new_apps.save_item_alternative(bigint, text, bigint, bigint, bigint, bigint, text, jsonb, boolean, numeric, integer, integer)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 25 $$;
