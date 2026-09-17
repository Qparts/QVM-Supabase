-- A line given its number is ready for quotation.
--
-- A line raised without a part number waits in Extract PN. When the pricing team types the number
-- in, the wait is over: the line moves to Ready For Quotation, logged like any other step. A line
-- further along — sent, priced, confirmed — keeps its status; only the number changes.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_quotation_item_part_number(p_quotation_item_id bigint, p_part_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_pn     text := NULLIF(btrim(COALESCE(p_part_number, '')), '');
  v_status integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can change a line''s part number';
  END IF;
  IF v_pn IS NULL THEN RAISE EXCEPTION 'A part number is required'; END IF;

  UPDATE qvm_new_apps.quotation_items
     SET part_number = v_pn,
         -- Extract PN (236) — or no status at all — becomes Ready For Quotation (235).
         item_status = CASE WHEN item_status IS NULL OR item_status = 236 THEN 235 ELSE item_status END,
         updated_at = now()
   WHERE quotation_item_id = p_quotation_item_id
  RETURNING item_status INTO v_status;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such line'; END IF;

  IF v_status = 235 AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.status_logs sl
        WHERE sl.quotation_item_id = p_quotation_item_id AND sl.item_status = 235) THEN
    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
    VALUES (p_quotation_item_id, 235, auth.uid());
  END IF;

  RETURN jsonb_build_object('status', 'success', 'quotation_item_id', p_quotation_item_id,
                            'part_number', v_pn, 'item_status', v_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 18 $$;
