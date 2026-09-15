-- The alternatives a vendor offers: who may read them, who may write them, and the two reference
-- lists the new grid needs.
--
-- Both pricing screens reach this: the vendor dashboard, where the caller has a session, and the
-- emailed magic link, where the caller has nothing but a token. Rather than write each function
-- twice, one gate answers for both — and it is the *gate* that is the security boundary here, not
-- the grant, because the token path has to be reachable by anon.

-- ── The gate ──────────────────────────────────────────────────────────────────────────────────
--
-- True when the caller may see and change this vendor line. Three ways to qualify, in the order
-- they are cheapest to check:
--   a valid, unexpired token whose quotation_vendor row owns the line;
--   a signed-in user whose user_vendor is the line's vendor;
--   the Qparts team, who price on a vendor's behalf.
--
-- A token that is expired or unknown fails here exactly as a missing one does, so a guessed token
-- learns nothing that a blank one would not.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_touch_vendor_cost(p_cost_id bigint, p_token uuid DEFAULT NULL)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM qvm_new_apps.quotation_vendor_items qvi
      JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
     WHERE qvi.cost_id = p_cost_id
       AND (
            (p_token IS NOT NULL AND qv.access_token = p_token AND now() <= qv.token_expires_at)
         OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data u
                     WHERE u.user_id = auth.uid() AND u.user_vendor = qvi.vendor_id)
         OR qvm_new_apps.is_qparts_team()
       )
  );
$function$;

-- ── The reference lists ───────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION qvm_new_apps.list_origin_countries()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'origin_country_id', c.origin_country_id,
           'code',    c.code,
           'name_en', c.name_en,
           'name_ar', c.name_ar) ORDER BY c.sort_order, c.name_en), '[]'::jsonb)
    FROM qvm_new_apps.origin_countries c
   WHERE c.is_active;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_part_brands()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'brand_id', ld.list_data_id,
           'brand_name', ld.list_data) ORDER BY ld.list_data), '[]'::jsonb)
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
   WHERE l.list_name = 'car_brand';
$function$;

-- ── Reading ───────────────────────────────────────────────────────────────────────────────────
--
-- Takes a set of cost_ids because the grid asks for a whole page of parts at once; lines the caller
-- may not touch are dropped silently rather than raising, so one stale id in a batch does not blank
-- the screen.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_item_alternatives(p_cost_ids bigint[], p_token uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alternative_id',      a.alternative_id,
           'cost_id',             a.cost_id,
           'part_number',         a.part_number,
           'brand_class',         a.brand_class,
           'brand_class_name',    bc.list_data,
           'brand_id',            a.brand_id,
           'brand_name',          br.list_data,
           'origin_country_id',   a.origin_country_id,
           'origin_country_name_en', oc.name_en,
           'origin_country_name_ar', oc.name_ar,
           'unit_price',          a.unit_price,
           'available_quantity',  a.available_quantity,
           'delivery_days',       a.delivery_days,
           'note',                a.note,
           'photos',              a.photos,
           'visible_to_workshop', a.visible_to_workshop,
           'created_at',          a.created_at) ORDER BY a.alternative_id), '[]'::jsonb)
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
   WHERE a.cost_id = ANY(p_cost_ids)
     AND qvm_new_apps.can_touch_vendor_cost(a.cost_id, p_token);
$function$;

-- ── Writing ───────────────────────────────────────────────────────────────────────────────────
--
-- One entry point for both insert and update: p_alternative_id NULL creates, an id updates. The
-- id is re-checked against p_cost_id so an update cannot be aimed at a row belonging to a line the
-- caller was never allowed to touch.
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

  IF p_alternative_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendor_item_alternatives
      (cost_id, part_number, brand_class, brand_id, origin_country_id, unit_price,
       available_quantity, delivery_days, note, photos, visible_to_workshop, created_by)
    VALUES
      (p_cost_id, btrim(p_part_number), p_brand_class, p_brand_id, p_origin_country_id, p_unit_price,
       p_available_quantity, p_delivery_days, NULLIF(btrim(COALESCE(p_note, '')), ''),
       COALESCE(p_photos, '[]'::jsonb), COALESCE(p_visible_to_workshop, false), auth.uid())
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
           visible_to_workshop = COALESCE(p_visible_to_workshop, a.visible_to_workshop),
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

-- The يظهر للورشة switch on its own, so flicking it does not re-send the whole row.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_vendor_item_alternative_visibility(
  p_alternative_id bigint, p_visible boolean, p_token uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_cost_id bigint;
BEGIN
  SELECT a.cost_id INTO v_cost_id
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
   WHERE a.alternative_id = p_alternative_id;

  IF v_cost_id IS NULL OR NOT qvm_new_apps.can_touch_vendor_cost(v_cost_id, p_token) THEN
    RAISE EXCEPTION 'Not allowed to change this alternative';
  END IF;

  UPDATE qvm_new_apps.quotation_vendor_item_alternatives
     SET visible_to_workshop = p_visible, updated_at = now()
   WHERE alternative_id = p_alternative_id;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_vendor_item_alternative(
  p_alternative_id bigint, p_token uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_cost_id bigint;
BEGIN
  SELECT a.cost_id INTO v_cost_id
    FROM qvm_new_apps.quotation_vendor_item_alternatives a
   WHERE a.alternative_id = p_alternative_id;

  IF v_cost_id IS NULL OR NOT qvm_new_apps.can_touch_vendor_cost(v_cost_id, p_token) THEN
    RAISE EXCEPTION 'Not allowed to remove this alternative';
  END IF;

  DELETE FROM qvm_new_apps.quotation_vendor_item_alternatives WHERE alternative_id = p_alternative_id;
  RETURN jsonb_build_object('status', 'success');
END;
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────
--
-- supabase.rpc() without a schema resolves against public. Every one of these is called that way
-- from the pricing pages, so without the wrapper it is a PGRST202 at run time and nowhere else.

CREATE OR REPLACE FUNCTION public.list_origin_countries()
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_origin_countries(); $$;

CREATE OR REPLACE FUNCTION public.list_part_brands()
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_part_brands(); $$;

CREATE OR REPLACE FUNCTION public.list_vendor_item_alternatives(p_cost_ids bigint[], p_token uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_vendor_item_alternatives(p_cost_ids, p_token); $$;

CREATE OR REPLACE FUNCTION public.save_vendor_item_alternative(
  p_cost_id bigint, p_part_number text, p_alternative_id bigint DEFAULT NULL,
  p_brand_class bigint DEFAULT NULL, p_brand_id bigint DEFAULT NULL, p_origin_country_id bigint DEFAULT NULL,
  p_unit_price numeric DEFAULT NULL, p_available_quantity integer DEFAULT NULL,
  p_delivery_days integer DEFAULT NULL, p_note text DEFAULT NULL, p_photos jsonb DEFAULT NULL,
  p_visible_to_workshop boolean DEFAULT NULL, p_token uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.save_vendor_item_alternative(
        p_cost_id, p_part_number, p_alternative_id, p_brand_class, p_brand_id, p_origin_country_id,
        p_unit_price, p_available_quantity, p_delivery_days, p_note, p_photos,
        p_visible_to_workshop, p_token); $$;

CREATE OR REPLACE FUNCTION public.set_vendor_item_alternative_visibility(
  p_alternative_id bigint, p_visible boolean, p_token uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.set_vendor_item_alternative_visibility(p_alternative_id, p_visible, p_token); $$;

CREATE OR REPLACE FUNCTION public.delete_vendor_item_alternative(p_alternative_id bigint, p_token uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.delete_vendor_item_alternative(p_alternative_id, p_token); $$;

-- anon is here for the magic link, which has no session at all. Every one of these functions
-- decides for itself through can_touch_vendor_cost, which without a valid token or a session
-- answers no — so the grant opens the door, not the data. The two reference lists are the
-- exception and are meant to be readable: they are facts about the catalogue.
REVOKE ALL ON FUNCTION public.list_origin_countries() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_part_brands() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_vendor_item_alternatives(bigint[], uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_vendor_item_alternative(bigint, text, bigint, bigint, bigint, bigint, numeric, integer, integer, text, jsonb, boolean, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_vendor_item_alternative_visibility(bigint, boolean, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_vendor_item_alternative(bigint, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_origin_countries() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_part_brands() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_vendor_item_alternatives(bigint[], uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_vendor_item_alternative(bigint, text, bigint, bigint, bigint, bigint, numeric, integer, integer, text, jsonb, boolean, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_vendor_item_alternative_visibility(bigint, boolean, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_vendor_item_alternative(bigint, uuid) TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION qvm_new_apps.can_touch_vendor_cost(bigint, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_origin_countries() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_part_brands() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_vendor_item_alternatives(bigint[], uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.save_vendor_item_alternative(bigint, text, bigint, bigint, bigint, bigint, numeric, integer, integer, text, jsonb, boolean, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.set_vendor_item_alternative_visibility(bigint, boolean, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.delete_vendor_item_alternative(bigint, uuid) TO anon, authenticated, service_role;
