BEGIN;

CREATE OR REPLACE FUNCTION public.get_orders_with_item_status(
  p_status_id integer,
  p_user_id uuid DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  SELECT jsonb_build_object(
    'status', 'success',
    'total_count', (SELECT COUNT(DISTINCT q.quotation_id)
                  FROM qvm_new_apps.quotation_items qi
                  JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
                  WHERE qi.item_status = p_status_id),
    'data', COALESCE(jsonb_agg(order_obj ORDER BY order_obj->>'created_at' DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_id', q.quotation_id,
      'order_number', q.order_number,
      'created_at', q.created_at,
      'account_manager', q.account_manager,
      'service_advisor', q.service_advisor,
      'customer_id', first_item.customer_id,
      'branch_name', cb.branch_name,
      'client_company', ld.list_data,
      'plate_number', q.plate_number,
      'vin', first_item.vin,
      'brand', COALESCE(vb.list_data, ''),
      'model', first_item.model,
      'items_count', item_counts.items_count,
      'items', items_json.items
    ) AS order_obj
    FROM (
      SELECT DISTINCT q.quotation_id
      FROM qvm_new_apps.quotation_items qi
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
      WHERE qi.item_status = p_status_id
      LIMIT GREATEST(1, COALESCE(p_limit, 100))
      OFFSET GREATEST(0, COALESCE(p_offset, 0))
    ) o
    JOIN qvm_new_apps.quotations q ON q.quotation_id = o.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.quotation_item_id, qi.customer_id, qi.part_description, qi.part_number, qi.vin, qi.main_brand, qi.model
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = o.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_item ON true
    LEFT JOIN qvm_new_apps.list_data vb ON vb.list_data_id = first_item.main_brand
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS items_count
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = o.quotation_id AND qi.item_status = p_status_id
    ) item_counts ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'quotation_item_id', qi.quotation_item_id,
        'part_number', COALESCE(ci.final_part_number, qi.part_number),
        'part_description', qi.part_description,
        'quantity', qi.quantity,
        'approved_qty', COALESCE(ci.approved_qty, qi.quantity),
        'price_before_vat', COALESCE(qi.price_before_vat, 0),
        'vat', 15,
        'discount_percent', COALESCE(qi.discount_percent, 0),
        'brand_class', COALESCE(bcls.list_data, '')
      ) ORDER BY qi.quotation_item_id), '[]'::jsonb) AS items
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data bcls ON bcls.list_data_id = COALESCE(ci.final_brand_class, qi.brand_class)
      WHERE qi.quotation_id = o.quotation_id AND qi.item_status = p_status_id
    ) items_json ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_item.customer_id
    LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = cb.list_data_id
  ) sub;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_orders_with_item_status(integer, uuid, int, int) TO authenticated;

COMMIT;
