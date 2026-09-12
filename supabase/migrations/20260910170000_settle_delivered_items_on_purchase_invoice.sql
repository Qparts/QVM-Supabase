-- Uploading the vendor's invoice settles the items that were already delivered.
--
-- 31 "Settled" is the end of the item ladder — updateQuotationItemStatus even ranks it highest —
-- but nothing in the app ever wrote it, so delivered items sat at 23 forever. The vendor invoice is
-- the last document a delivered line is waiting for: goods out, invoice in, nothing owed to the
-- process. That is what settles it.
--
-- Only lines already Delivered move. Anything still on its way is untouched — an invoice arriving
-- early must not settle goods nobody has received — and so is anything cancelled, returned, or
-- carrying a pending request, none of which are Delivered by definition.
--
-- Both tables are written: confirmed_items is the source the purchase-order screens read, and the
-- sync mirrors it onto the quotation line the dashboards read. Writing only one of them would be
-- undone the next time the other changed.

CREATE OR REPLACE FUNCTION qvm_new_apps.settle_delivered_items(p_quotation_item_ids integer[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ci record;
  v_confirmed int := 0;
  v_quotation_only int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;
  IF p_quotation_item_ids IS NULL OR array_length(p_quotation_item_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('settled', 0));
  END IF;

  FOR v_ci IN
    SELECT ci.confirmed_item_id
    FROM qvm_new_apps.confirmed_items ci
    WHERE ci.quotation_item_id = ANY(p_quotation_item_ids)
      AND ci.item_status = 23
  LOOP
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 31, updated_by = v_uid, updated_at = now()
    WHERE confirmed_item_id = v_ci.confirmed_item_id;

    INSERT INTO qvm_new_apps.status_logs(confirmed_item_id, item_status, status_changed_by)
    VALUES (v_ci.confirmed_item_id, 31, v_uid);

    PERFORM qvm_new_apps.sync_confirmed_item_to_quotation(v_ci.confirmed_item_id);
    v_confirmed := v_confirmed + 1;
  END LOOP;

  -- A delivered quotation line with no confirmed row behind it still settles; there is simply
  -- nothing to mirror from.
  WITH moved AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET item_status = 31, updated_at = now()
    WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
      AND qi.item_status = 23
      AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.confirmed_items ci
                       WHERE ci.quotation_item_id = qi.quotation_item_id)
    RETURNING 1
  )
  SELECT count(*) INTO v_quotation_only FROM moved;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'settled', v_confirmed + v_quotation_only,
    'via_confirmed_items', v_confirmed,
    'quotation_only', v_quotation_only));
END;
$function$;

-- supabase.rpc() with no schema resolves against public.
CREATE OR REPLACE FUNCTION public.settle_delivered_items(p_quotation_item_ids integer[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.settle_delivered_items(p_quotation_item_ids);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.settle_delivered_items(integer[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.settle_delivered_items(integer[]) TO authenticated;
