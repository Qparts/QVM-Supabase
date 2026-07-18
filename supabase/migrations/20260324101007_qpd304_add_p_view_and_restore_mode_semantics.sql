-- Synced from QVM/test branch applied migration history (version 20260324101007, name: qpd304_add_p_view_and_restore_mode_semantics)
-- QPD-304: Add p_view (rfqs|orders|all) and restore p_mode semantics (client type)
-- Drop existing function to change signature
DROP FUNCTION IF EXISTS public.get_internal_dashboard(
  uuid, text, timestamptz, timestamptz, uuid[], int[], int[], int[], int[], text, int, int
);

CREATE FUNCTION public.get_internal_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_account_managers uuid[] DEFAULT NULL,
  p_clients int[] DEFAULT NULL,
  p_branches int[] DEFAULT NULL,
  p_brands int[] DEFAULT NULL,
  p_statuses int[] DEFAULT NULL,
  p_mode text DEFAULT 'regular', -- client type: 'regular' or 'bulk' (NULL = all)
  p_view text DEFAULT 'rfqs',    -- dataset: 'rfqs' | 'orders' | 'all'
  p_limit int DEFAULT 1000,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  -- Ensure only internal users can access
  SELECT user_type INTO v_user_type FROM qvm_new_apps.user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only','data','[]'::jsonb);
  END IF;

  WITH filtered_quotations AS (
    SELECT DISTINCT
      q.quotation_id,
      q.order_number,
      q.plate_number,
      q.created_at AS rfq_date,
      q.service_advisor,
      q.delivery_type,
      q.order_type,
      q.shipping_price,
      q.shipping_type,
      q.account_manager,
      co.confirmed_order_id,
      co.created_at AS confirmation_date,
      (
        SELECT qi.customer_id
        FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC
        LIMIT 1
      ) AS customer_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = q.quotation_id
    WHERE
      (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_account_managers IS NULL OR q.account_manager = ANY(p_account_managers))
      AND (
        p_view IS NULL OR p_view = 'all'
        OR (p_view = 'rfqs' AND co.confirmed_order_id IS NULL)
        OR (p_view = 'orders' AND co.confirmed_order_id IS NOT NULL)
      )
      AND (
        p_search IS NULL
        OR q.order_number ILIKE concat('%', p_search, '%')
        OR q.plate_number ILIKE concat('%', p_search, '%')
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          LEFT JOIN qvm_new_apps.confirmed_items cis ON cis.quotation_item_id = qis.quotation_item_id
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE concat('%', p_search, '%')
              OR qis.part_description ILIKE concat('%', p_search, '%')
              OR qis.vin ILIKE concat('%', p_search, '%')
              OR cis.final_part_number ILIKE concat('%', p_search, '%')
            )
        )
      )
  ),
  filtered_with_branch AS (
    SELECT
      fq.*,
      cb.customer_id AS branch_id,
      cb.branch_name,
      cb.list_data_id AS client_id,
      cb.is_bulk_client,
      ld_client.list_data AS client_name
    FROM filtered_quotations fq
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fq.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    WHERE
      (p_branches IS NULL OR cb.customer_id = ANY(p_branches))
      AND (p_clients IS NULL OR cb.list_data_id = ANY(p_clients))
      AND (
        p_mode IS NULL
        OR (p_mode = 'bulk' AND cb.is_bulk_client = true)
        OR (p_mode = 'regular' AND (cb.is_bulk_client = false OR cb.is_bulk_client IS NULL))
      )
  ),
  ordered_rows AS (
    SELECT fwb.*
    FROM filtered_with_branch fwb
    ORDER BY fwb.rfq_date DESC
    LIMIT p_limit OFFSET p_offset
  ),
  row_objects AS (
    SELECT jsonb_build_object(
      'quotation_id', fwb.quotation_id,
      'confirmed_order_id', fwb.confirmed_order_id,
      'order_number', fwb.order_number,
      'plate_number', fwb.plate_number,
      'rfq_date', fwb.rfq_date,
      'confirmation_date', fwb.confirmation_date,
      'branch_id', fwb.branch_id,
      'branch_name', fwb.branch_name,
      'client_id', fwb.client_id,
      'client_name', fwb.client_name,
      'is_bulk_client', fwb.is_bulk_client,
      'service_advisor', sa.user_name,
      'service_advisor_id', fwb.service_advisor,
      'delivery_type', ld_delivery.list_data,
      'delivery_type_id', fwb.delivery_type,
      'order_type', ld_order.list_data,
      'order_type_id', fwb.order_type,
      'shipping_price', fwb.shipping_price,
      'shipping_type', fwb.shipping_type,
      'account_manager', am.user_name,
      'account_manager_id', fwb.account_manager,
      'account_manager_history', (
        SELECT COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'account_manager_id', COALESCE(qam.assigned_to, qam.assigned_from),
              'account_manager_name', COALESCE(am_to.user_name, am_from.user_name),
              'assigned_at', qam.created_at
            )
            ORDER BY qam.created_at DESC
          ), '[]'::jsonb
        )
        FROM qvm_new_apps.quotation_account_managers qam
        LEFT JOIN qvm_new_apps.user_data am_from ON am_from.user_id = qam.assigned_from
        LEFT JOIN qvm_new_apps.user_data am_to ON am_to.user_id = qam.assigned_to
        WHERE qam.quotation_id = fwb.quotation_id
      ),
      'items', (
        SELECT COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'quotation_item_id', qi.quotation_item_id,
              'vin', qi.vin,
              'main_brand', ld_brand.list_data,
              'main_brand_id', qi.main_brand,
              'model', qi.model,
              'year', qi.year,
              'part_number', qi.part_number,
              'part_description', qi.part_description,
              'quantity', qi.quantity,
              'brand_class', ld_bc.list_data,
              'brand_class_id', qi.brand_class,
              'alternative_part_number', qi.alternative_part_number,
              'alternative_brand_class', ld_abc.list_data,
              'alternative_brand_class_id', qi.alternative_brand_class,
              'part_photo', qi.part_photo,
              'estimated_price', qi.estimated_price,
              'price_before_vat', qi.price_before_vat,
              'discount_percent', qi.discount_percent,
              'agency_price', qi.agency_price,
              'total_price_before_vat', qi.total_price_before_vat,
              'item_status', ld_status.list_data,
              'item_status_id', qi.item_status,
              'part_category', ld_category.list_data,
              'part_category_id', qi.part_category,
              'final_part_number', ci.final_part_number,
              'approved_qty', ci.approved_qty,
              'final_brand_class', ld_fbc.list_data,
              'final_brand_class_id', ci.final_brand_class,
              'return_type', ld_return.list_data,
              'return_type_id', ci.return_type,
              'client_return_reason', ci.client_return_reason,
              'cancellation_reason', ld_cancel.list_data,
              'cancellation_reason_id', ci.cancellation_reason,
              'purchase_cost', qvi.cost,
              'purchase_supplier', qvi.vendor_id,
              'item_notes', (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'note_id', n.note_id,
                    'note_text', n.note_description,
                    'created_by', n_creator.user_name,
                    'created_at', n.created_at
                  ) ORDER BY n.created_at DESC
                )
                FROM qvm_new_apps.notes n
                LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
                WHERE n.note_type = 'quotation_items'
                  AND n.type_id = qi.quotation_item_id
                  AND n.is_internal = false
              )
            ) ORDER BY qi.quotation_item_id
          ), '[]'::jsonb
        )
        FROM qvm_new_apps.quotation_items qi
        LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
        LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi.main_brand
        LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
        LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = qi.item_status
        LEFT JOIN qvm_new_apps.list_data ld_category ON ld_category.list_data_id = qi.part_category
        LEFT JOIN qvm_new_apps.list_data ld_fbc ON ld_fbc.list_data_id = ci.final_brand_class
        LEFT JOIN qvm_new_apps.list_data ld_return ON ld_return.list_data_id = ci.return_type
        LEFT JOIN qvm_new_apps.list_data ld_cancel ON ld_cancel.list_data_id = ci.cancellation_reason
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
        WHERE qi.quotation_id = fwb.quotation_id
          AND (p_brands IS NULL OR qi.main_brand = ANY(p_brands))
          AND (p_statuses IS NULL OR qi.item_status = ANY(p_statuses))
          -- Do not filter items by p_search here; header search handled above
      ),
      'quotation_notes', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'note_id', n.note_id,
            'note_text', n.note_description,
            'created_by', n_creator.user_name,
            'created_at', n.created_at
          ) ORDER BY n.created_at DESC
        )
        FROM qvm_new_apps.notes n
        LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
        WHERE n.note_type = 'quotations'
          AND n.type_id = fwb.quotation_id
          AND n.is_internal = false
      ),
      'payment_account', (
        SELECT ld_payment.list_data
        FROM qvm_new_apps.purchase_orders po
        LEFT JOIN qvm_new_apps.list_data ld_payment ON ld_payment.list_data_id = po.payment_account
        WHERE po.confirmed_order_id = fwb.confirmed_order_id
        LIMIT 1
      ),
      'payment_account_id', (
        SELECT po.payment_account
        FROM qvm_new_apps.purchase_orders po
        WHERE po.confirmed_order_id = fwb.confirmed_order_id
        LIMIT 1
      )
    ) AS obj
    FROM ordered_rows fwb
    LEFT JOIN qvm_new_apps.user_data sa ON sa.user_id = fwb.service_advisor
    LEFT JOIN qvm_new_apps.user_data am ON am.user_id = fwb.account_manager
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = fwb.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = fwb.order_type
  )
  SELECT jsonb_build_object(
    'status','success',
    'message','Internal dashboard data fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered_with_branch),
    'data', COALESCE((SELECT jsonb_agg(obj) FROM row_objects), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- Permissions for authenticated role
REVOKE EXECUTE ON FUNCTION public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], int[], int[], int[], int[], text, text, int, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], int[], int[], int[], int[], text, text, int, int) TO authenticated;;
