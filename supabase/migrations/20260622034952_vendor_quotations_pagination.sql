-- Synced from QVM/test branch applied migration history (version 20260622034952, name: vendor_quotations_pagination)
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotations(
  p_vendor_id bigint,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 100,
  p_order_number text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
AS $function$
DECLARE
  result JSON;
  total_count INT;
  offset_val INT;
BEGIN
  offset_val := GREATEST((p_page - 1) * p_page_size, 0);

  SELECT COUNT(*)
  INTO total_count
  FROM qvm_new_apps.quotation_vendors qv
  JOIN qvm_new_apps.quotations q ON qv.quotation_id = q.quotation_id
  WHERE qv.vendor_id = p_vendor_id::INT
    AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%');

  SELECT json_build_object(
    'status', 'success',
    'message', 'Vendor quotations fetched successfully',
    'total_count', total_count,
    'data', COALESCE(json_agg(
      json_build_object(
        'quotation_vendor_id', qv.quotation_vendor_id,
        'quotation_id', q.quotation_id,
        'date_sent', qv.created_at,
        'order_number', q.order_number,
        'vendor_status', qv.vendor_status,
        'vin_numbers', (
          SELECT json_agg(DISTINCT qi.vin)
          FROM qvm_new_apps.quotation_items qi
          WHERE qi.quotation_id = q.quotation_id
        ),
        'main_brands', (
          SELECT json_agg(DISTINCT ld.list_data)
          FROM qvm_new_apps.quotation_items qi2
          LEFT JOIN qvm_new_apps.list_data ld
            ON ld.list_data_id = qi2.main_brand
          WHERE qi2.quotation_id = q.quotation_id
        ),
        'models', (
          SELECT json_agg(DISTINCT qi3.model)
          FROM qvm_new_apps.quotation_items qi3
          WHERE qi3.quotation_id = q.quotation_id
        ),
        'total_quotation_price', (
          SELECT COALESCE(SUM(qvi.cost), 0)
          FROM qvm_new_apps.quotation_vendor_items qvi
          WHERE qvi.quotation_vendor_id = qv.quotation_vendor_id
        ),
        'number_of_parts', (
          SELECT COUNT(*)
          FROM qvm_new_apps.quotation_vendor_items qvi2
          WHERE qvi2.quotation_vendor_id = qv.quotation_vendor_id
        ),
        'order_notes', (
          SELECT json_agg(
            json_build_object(
              'note_description', n.note_description,
              'note_attachment', n.note_attachment,
              'created_at', n.created_at,
              'user_name', u.user_name
            )
            ORDER BY n.created_at DESC
          )
          FROM qvm_new_apps.notes n
          LEFT JOIN qvm_new_apps.user_data u
            ON u.user_id = n.user_id
          WHERE n.note_type = 'quotation_vendor'
            AND n.type_id = qv.quotation_vendor_id
            AND n.is_internal = FALSE
        )
      )
      ORDER BY qv.created_at DESC
    ), '[]'::JSON)
  )
  INTO result
  FROM qvm_new_apps.quotation_vendors qv
  JOIN qvm_new_apps.quotations q ON qv.quotation_id = q.quotation_id
  WHERE qv.vendor_id = p_vendor_id::INT
    AND (p_order_number IS NULL OR p_order_number = '' OR q.order_number ILIKE '%' || p_order_number || '%')
  ORDER BY qv.created_at DESC
  LIMIT p_page_size
  OFFSET offset_val;

  RETURN result;
END;
$function$;
;
