CREATE OR REPLACE FUNCTION public.cancel_rfq_items(
  p_quotation_item_ids integer[],
  p_cancellation_reason integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, qvm_new_apps
AS $$
DECLARE
  v_new_status integer := 18;
  v_updated integer := 0;
  v_updated_ids integer[];
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_quotation_item_ids IS NULL OR array_length(p_quotation_item_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing or invalid input (quotation_item_ids)');
  END IF;

  WITH updated AS (
    UPDATE qvm_new_apps.quotation_items
    SET item_status = v_new_status,
        cancellation_reason = COALESCE(p_cancellation_reason, cancellation_reason),
        updated_at = now()
    WHERE quotation_item_id = ANY(p_quotation_item_ids)
    RETURNING quotation_item_id
  )
  SELECT
    COALESCE(count(*), 0)::integer,
    COALESCE(array_agg(quotation_item_id), '{}'::integer[])
  INTO v_updated, v_updated_ids
  FROM updated;

  IF v_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No quotation_items were updated', 'updated', 0);
  END IF;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
  SELECT unnest(v_updated_ids), v_new_status, auth.uid();

  RETURN jsonb_build_object('success', true, 'updated', v_updated);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_rfq_items(integer[], integer) TO authenticated;
