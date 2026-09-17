-- A model that is not on the list can be added from the form.
--
-- The list is the team's; the market keeps producing models. When the person raising an RFQ picks
-- «Other» for a brand, or types a model nothing matches, they may save it under that brand there and
-- then — for themselves now, and for everyone after. Same name twice under one brand returns the
-- existing row rather than a second one.

CREATE OR REPLACE FUNCTION qvm_new_apps.add_vehicle_model(p_brand_id bigint, p_name_en text, p_name_ar text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF COALESCE(btrim(p_name_en), '') = '' THEN RAISE EXCEPTION 'A model needs a name'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld
                  JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id AND l.list_name = 'car_brand'
                 WHERE ld.list_data_id = p_brand_id) THEN
    RAISE EXCEPTION 'That is not a vehicle brand';
  END IF;

  INSERT INTO qvm_new_apps.vehicle_models (brand_id, name_en, name_ar)
  VALUES (p_brand_id, btrim(p_name_en), NULLIF(btrim(COALESCE(p_name_ar, '')), ''))
  ON CONFLICT (brand_id, lower(name_en)) DO UPDATE
    -- Re-adding an existing name is a lookup, not a change; the Arabic is filled in only if it was empty.
    SET name_ar = COALESCE(qvm_new_apps.vehicle_models.name_ar, EXCLUDED.name_ar), is_active = true
  RETURNING model_id INTO v_id;

  RETURN jsonb_build_object('status', 'success', 'model_id', v_id, 'name_en', btrim(p_name_en));
END;
$function$;
CREATE OR REPLACE FUNCTION public.add_vehicle_model(p_brand_id bigint, p_name_en text, p_name_ar text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.add_vehicle_model(p_brand_id, p_name_en, p_name_ar); $$;
REVOKE ALL ON FUNCTION public.add_vehicle_model(bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_vehicle_model(bigint, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.add_vehicle_model(bigint, text, text) TO authenticated, service_role;
