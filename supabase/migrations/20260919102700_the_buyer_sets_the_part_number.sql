-- The buyer may set any line's part number.
--
-- Until now the pricing page could only type a number onto a line that had none, and it landed in
-- the stand-in field (alternative_part_number). The number every vendor quotes against is
-- quotation_items.part_number, and the pricing team is the one that corrects it — a typo from the
-- workshop, a superseded number, the vendor's proposal accepted by hand. One small function, team
-- only, that writes exactly that field.

CREATE OR REPLACE FUNCTION qvm_new_apps.set_quotation_item_part_number(p_quotation_item_id bigint, p_part_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_pn text := NULLIF(btrim(COALESCE(p_part_number, '')), '');
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can change a line''s part number';
  END IF;
  IF v_pn IS NULL THEN RAISE EXCEPTION 'A part number is required'; END IF;
  UPDATE qvm_new_apps.quotation_items
     SET part_number = v_pn, updated_at = now()
   WHERE quotation_item_id = p_quotation_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such line'; END IF;
  RETURN jsonb_build_object('status', 'success', 'quotation_item_id', p_quotation_item_id, 'part_number', v_pn);
END;
$function$;
CREATE OR REPLACE FUNCTION public.set_quotation_item_part_number(p_quotation_item_id bigint, p_part_number text)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.set_quotation_item_part_number(p_quotation_item_id, p_part_number); $$;
REVOKE ALL ON FUNCTION public.set_quotation_item_part_number(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_quotation_item_part_number(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.set_quotation_item_part_number(bigint, text) TO authenticated, service_role;
