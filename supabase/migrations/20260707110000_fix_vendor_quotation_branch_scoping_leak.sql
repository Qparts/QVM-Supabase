-- Bug: get_vendor_quotation_by_token called get_vendor_quotation_details(quotation_id, vendor_id, NULL).
-- NULL disables the branch filter, so when the same vendor has more than one quotation_vendors row
-- for the same quotation (one per branch it was sent to), the token for ONE branch's row returned
-- items belonging to the vendor's OTHER branch too. The vendor could then submit a price for an item
-- that was never actually sent to that branch, whose cost_id belongs to a different quotation_vendor_id
-- — correctly rejected by save_vendor_quotation_by_token's ownership check, but the read side should
-- never have shown it in the first place.
--
-- Fix 1: resolve the token's own vendor_branch_id and scope get_vendor_quotation_details() to it.
-- (Legacy vendors with no branch model have vendor_branch_id NULL and only ever get one
-- quotation_vendors row per quotation — see create_vendors_quotations' NOT DISTINCT FROM lookup —
-- so passing NULL through unchanged for them is still correct/unambiguous.)
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_quotation_id integer;
  v_vendor_id integer;
  v_vendor_branch_id bigint;
  v_expires_at timestamptz;
BEGIN
  SELECT qv.quotation_id, qv.vendor_id, qv.vendor_branch_id, qv.token_expires_at
  INTO v_quotation_id, v_vendor_id, v_vendor_branch_id, v_expires_at
  FROM qvm_new_apps.quotation_vendors qv
  WHERE qv.access_token = p_token;

  IF v_quotation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF now() > v_expires_at THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  RETURN qvm_new_apps.get_vendor_quotation_details(
    v_quotation_id,
    v_vendor_id,
    CASE WHEN v_vendor_branch_id IS NULL THEN NULL ELSE ARRAY[v_vendor_branch_id] END
  );
END;
$function$;

-- Fix 2 (defense in depth): the vendor_pricing subquery only filtered by vendor_id, not by which
-- quotation_vendor row(s) the outer query already resolved — so even with fix 1, a vendor with the
-- same quotation_item sent under two different quotation_vendor rows could see the wrong cost_id.
-- This also fixes the same latent leak for the authenticated vendor dashboard, not just the token page.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_ids BIGINT[];
    v_vendor_status INT;
BEGIN
    SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
    INTO v_quotation_vendor_ids, v_vendor_status
    FROM qvm_new_apps.quotation_vendors qv
    WHERE qv.quotation_id = p_quotation_id
      AND qv.vendor_id = p_vendor_id
      AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids));

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_ids[1],
            'vendor_status', v_vendor_status,
            'quotation', (
                SELECT jsonb_build_object(
                    'quotation_id', q.quotation_id,
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'account_manager', q.account_manager,
                    'created_at', q.created_at,
                    'updated_at', q.updated_at
                )
                FROM qvm_new_apps.quotations q
                WHERE q.quotation_id = p_quotation_id
            ),
            'items', (
                SELECT json_agg(t.obj)
                FROM (
                    SELECT DISTINCT ON (qi.quotation_item_id)
                        json_build_object(
                            'quotation_item_id', qi.quotation_item_id,
                            'vin', qi.vin,
                            'main_brand', qi.main_brand,
                            'main_brand_name', main_brand_ld.list_data,
                            'model', qi.model,
                            'part_description', qi.part_description,
                            'part_number', qi.part_number,
                            'quantity', qi.quantity,
                            'brand_class', qi.brand_class,
                            'brand_class_name', brand_class_ld.list_data,
                            'part_category', qi.part_category,
                            'part_category_name', part_category_ld.list_data,
                            'part_photo', qi.part_photo,
                            'item_status', qi.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'alternative_part_number', qi.alternative_part_number,
                            'created_at', qi.created_at,
                            'updated_at', qi.updated_at,
                            'vendor_pricing', (
                                SELECT COALESCE(
                                    json_agg(
                                        json_build_object(
                                            'cost_id', qvi2.cost_id,
                                            'cost', qvi2.cost,
                                            'vendor_id', qvi2.vendor_id,
                                            'vendor_item_status', qvi2.vendor_item_status,
                                            'discount_percent', qvi2.discount_percent,
                                            'agency_price', qvi2.agency_price,
                                            'sla', qvi2.sla,
                                            'best_cost', qvi2.best_cost,
                                            'available_quantity', qvi2.available_quantity,
                                            'quotation_vendor_id', qvi2.quotation_vendor_id,
                                            'available_brand_class', qvi2.available_brand_class,
                                            'alternative_part_number', qvi2.alternative_part_number,
                                            'created_at', qvi2.created_at,
                                            'updated_at', qvi2.updated_at,
                                            'item_notes', (
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
                                                WHERE n.note_type = 'quotation_vendor_item'
                                                  AND n.type_id = qvi2.cost_id
                                                  AND n.is_internal = FALSE
                                            )
                                        )
                                    ),
                                    '[]'::json
                                )
                                FROM qvm_new_apps.quotation_vendor_items qvi2
                                WHERE qvi2.quotation_item_id = qi.quotation_item_id
                                  AND qvi2.vendor_id = p_vendor_id
                                  AND qvi2.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                            )
                        ) AS obj
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    JOIN qvm_new_apps.quotation_items qi
                      ON qi.quotation_item_id = qvi.quotation_item_id
                    LEFT JOIN qvm_new_apps.list_data main_brand_ld
                           ON qi.main_brand = main_brand_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data brand_class_ld
                           ON qi.brand_class = brand_class_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data part_category_ld
                           ON qi.part_category = part_category_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld
                           ON qi.item_status = item_status_ld.list_data_id
                    WHERE qvi.vendor_id = p_vendor_id
                      AND qvi.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                    ORDER BY qi.quotation_item_id
                ) t
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;
