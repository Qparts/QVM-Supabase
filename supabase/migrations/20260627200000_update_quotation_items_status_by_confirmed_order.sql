BEGIN;

CREATE OR REPLACE FUNCTION public.update_quotation_items_status_by_confirmed_order(
  p_confirmed_order_id integer,
  p_status_id integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_updated_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
  END IF;

  IF p_confirmed_order_id IS NULL OR p_status_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'confirmed_order_id and status_id are required');
  END IF;

  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = p_status_id,
      updated_at = now()
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_order_id = p_confirmed_order_id
    AND qi.quotation_item_id = ci.quotation_item_id;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT ci.quotation_item_id, p_status_id, auth.uid(), now()
  FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_order_id = p_confirmed_order_id
    AND auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'updated_count', v_updated_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_quotation_items_status_by_confirmed_order(integer, integer) TO authenticated;

COMMIT;
