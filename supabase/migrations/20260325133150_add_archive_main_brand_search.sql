-- Synced from QVM/test branch applied migration history (version 20260325133150, name: add_archive_main_brand_search)
BEGIN;

CREATE OR REPLACE FUNCTION public.get_archive_note_rows(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_type text DEFAULT 'all',
  p_company_id integer DEFAULT NULL,
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamp with time zone DEFAULT NULL,
  p_date_to timestamp with time zone DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  dn_rows json;
  rn_rows json;
  s text := coalesce(p_search, '');
  typ text := coalesce(p_type, 'all');
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
    INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  IF typ <> 'rn' THEN
    SELECT coalesce(json_agg(t), '[]'::json) INTO dn_rows
    FROM (
      SELECT dn.*,
        qi.vin,
        cb.customer_id AS branch_id,
        cb.branch_name,
        cb.list_data_id AS company_id,
        ld_company.list_data AS company_name,
        di.delivery_id,
        d.delivery_date,
        ld_status.list_data AS status
      FROM qvm_new_apps.delivery_notes dn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = dn.confirmed_item_id
        JOIN qvm_new_apps.delivery_items di ON di.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.deliveries d ON d.delivery_id = di.delivery_id
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice',
          'pending credit note',
          'invoice issued',
          'credit note issued',
          'settled',
          'claim sent',
          'return request',
          'return'
        )
        AND (p_date_from IS NULL OR d.delivery_date >= p_date_from)
        AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
        AND (
          v_is_internal
          OR (v_user_role = 170 AND cb.list_data_id = v_company)
          OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
        )
        AND (
          NOT v_is_internal
          OR (p_company_id IS NULL OR cb.list_data_id = p_company_id)
        )
        AND (
          NOT v_is_internal
          OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id)
        )
        AND (
          s = '' OR
          position(lower(s) in lower(coalesce(dn.order_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(dn.plate_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(dn.main_brand, ''))) > 0 OR
          position(lower(s) in lower(coalesce(dn.model, ''))) > 0 OR
          position(lower(s) in lower(coalesce(qi.vin, ''))) > 0
        )
    ) t;
  ELSE
    dn_rows := '[]'::json;
  END IF;

  IF typ <> 'dn' THEN
    SELECT coalesce(json_agg(t), '[]'::json) INTO rn_rows
    FROM (
      SELECT rn.*,
        qi.vin,
        cb.customer_id AS branch_id,
        cb.branch_name,
        cb.list_data_id AS company_id,
        ld_company.list_data AS company_name,
        ri.return_id,
        r.return_date,
        ld_status.list_data AS status
      FROM qvm_new_apps.return_notes rn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = rn.confirmed_item_id
        JOIN qvm_new_apps.return_items ri ON ri.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.returns r ON r.return_id = ri.return_id
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice',
          'pending credit note',
          'invoice issued',
          'credit note issued',
          'settled',
          'claim sent',
          'return request',
          'return'
        )
        AND (p_date_from IS NULL OR r.return_date >= p_date_from)
        AND (p_date_to IS NULL OR r.return_date <= p_date_to)
        AND (
          v_is_internal
          OR (v_user_role = 170 AND cb.list_data_id = v_company)
          OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
        )
        AND (
          NOT v_is_internal
          OR (p_company_id IS NULL OR cb.list_data_id = p_company_id)
        )
        AND (
          NOT v_is_internal
          OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id)
        )
        AND (
          s = '' OR
          position(lower(s) in lower(coalesce(rn.order_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(rn.plate_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(rn.main_brand, ''))) > 0 OR
          position(lower(s) in lower(coalesce(rn.model, ''))) > 0 OR
          position(lower(s) in lower(coalesce(qi.vin, ''))) > 0
        )
    ) t;
  ELSE
    rn_rows := '[]'::json;
  END IF;

  RETURN json_build_object('dn', coalesce(dn_rows, '[]'::json), 'rn', coalesce(rn_rows, '[]'::json));
END;
$$;

REVOKE ALL ON FUNCTION public.get_archive_note_rows(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_archive_note_rows(uuid, text, text, integer, integer, timestamp with time zone, timestamp with time zone) TO service_role;

COMMIT;
;
