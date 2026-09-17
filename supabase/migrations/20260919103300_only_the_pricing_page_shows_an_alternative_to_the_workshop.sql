-- Only the pricing page shows an alternative to the workshop.
--
-- The vendor proposes; the pricing team decides what the workshop is offered. A vendor's save can
-- no longer turn the flag on, the visibility call is the Qparts team's alone, and every flag set
-- before this rule is cleared — from here on, an alternative the workshop can see is one somebody
-- on the pricing page chose to show.
CREATE OR REPLACE FUNCTION qvm_new_apps.save_vendor_item_alternative(
  p_cost_id             bigint,
  p_part_number         text,
  p_alternative_id      bigint  DEFAULT NULL,
  p_brand_class         bigint  DEFAULT NULL,
  p_brand_id            bigint  DEFAULT NULL,
  p_origin_country_id   bigint  DEFAULT NULL,
  p_unit_price          numeric DEFAULT NULL,
  p_available_quantity  integer DEFAULT NULL,
  p_delivery_days       integer DEFAULT NULL,
  p_note                text    DEFAULT NULL,
  p_photos              jsonb   DEFAULT NULL,
  p_visible_to_workshop boolean DEFAULT NULL,
  p_token               uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.can_touch_vendor_cost(p_cost_id, p_token) THEN
    RAISE EXCEPTION 'Not allowed to price this line';
  END IF;

  IF COALESCE(btrim(p_part_number), '') = '' THEN
    RAISE EXCEPTION 'An alternative needs a part number';
  END IF;

  -- Genuine means genuine: the origin is the Genuine row, not a country the client picked.
  IF qvm_new_apps.is_genuine_class(p_brand_class) THEN
    p_origin_country_id := qvm_new_apps.genuine_origin_id();
  END IF;

  IF p_alternative_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
      (cost_id, part_number, brand_class, brand_id, origin_country_id, unit_price,
       available_quantity, delivery_days, note, photos, visible_to_workshop, created_by)
    VALUES
      (p_cost_id, btrim(p_part_number), p_brand_class, p_brand_id, p_origin_country_id, p_unit_price,
       p_available_quantity, p_delivery_days, NULLIF(btrim(COALESCE(p_note, '')), ''),
       COALESCE(p_photos, '[]'::jsonb),
       -- Whether the workshop sees it is the pricing team's call. A vendor's save never turns it on.
       CASE WHEN qvm_new_apps.is_qparts_team() THEN COALESCE(p_visible_to_workshop, false) ELSE false END,
       auth.uid())
    RETURNING alternative_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.quotation_vendor_item_alternatives a
       SET part_number         = btrim(p_part_number),
           brand_class         = p_brand_class,
           brand_id            = p_brand_id,
           origin_country_id   = p_origin_country_id,
           unit_price          = p_unit_price,
           available_quantity  = p_available_quantity,
           delivery_days       = p_delivery_days,
           note                = NULLIF(btrim(COALESCE(p_note, '')), ''),
           -- Photos are uploaded and removed by their own call; a save that does not mention them
           -- must not wipe them.
           photos              = COALESCE(p_photos, a.photos),
           visible_to_workshop = CASE WHEN qvm_new_apps.is_qparts_team()
                                      THEN COALESCE(p_visible_to_workshop, a.visible_to_workshop)
                                      ELSE a.visible_to_workshop END,
           updated_at          = now()
     WHERE a.alternative_id = p_alternative_id
       AND a.cost_id = p_cost_id
    RETURNING a.alternative_id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'That alternative is not on this line';
    END IF;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'alternative_id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_item_alternative_visibility(
  p_alternative_id bigint, p_visible boolean, p_token uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the pricing team decides what the workshop sees';
  END IF;

  UPDATE qvm_new_apps.quotation_vendor_item_alternatives
     SET visible_to_workshop = p_visible, updated_at = now()
   WHERE alternative_id = p_alternative_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'That alternative does not exist';
  END IF;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

UPDATE qvm_new_apps.quotation_vendor_item_alternatives
   SET visible_to_workshop = false, updated_at = now()
 WHERE visible_to_workshop;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 7 $$;
