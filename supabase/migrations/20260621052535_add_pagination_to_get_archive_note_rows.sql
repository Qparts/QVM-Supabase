-- Synced from QVM/test branch applied migration history (version 20260621052535, name: add_pagination_to_get_archive_note_rows)
CREATE OR REPLACE FUNCTION public.get_archive_note_rows(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_type text DEFAULT 'all',
  p_company_id integer DEFAULT NULL,
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamp with time zone DEFAULT NULL,
  p_date_to timestamp with time zone DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  dn_rows json;
  rn_rows json;
  dn_count bigint := 0;
  rn_count bigint := 0;
  s text := coalesce(p_search, '');
  typ text := coalesce(p_type, 'all');
  lim int := coalesce(p_limit, 50);
  off int := coalesce(p_offset, 0);
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
    SELECT count(*) INTO dn_count
    FROM (
      SELECT dn.confirmed_item_id
      FROM qvm_new_apps.delivery_notes dn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = dn.confirmed_item_id
        JOIN qvm_new_apps.delivery_items di ON di.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.deliveries d ON d.delivery_id = di.delivery_id
        LEFT JOIN qvm_new_apps.invoices inv ON inv.invoice_id = di.invoice_id
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice','pending credit note','invoice issued','credit note issued','settled','claim sent','return request','return'
        )
        AND (p_date_from IS NULL OR d.delivery_date >= p_date_from)
        AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
        AND (v_is_internal OR (v_user_role = 170 AND cb.list_data_id = v_company) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
        AND (NOT v_is_internal OR (p_company_id IS NULL OR cb.list_data_id = p_company_id))
        AND (NOT v_is_internal OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id))
        AND (s = '' OR position(lower(s) in lower(coalesce(dn.order_number,''))) > 0 OR position(lower(s) in lower(coalesce(dn.plate_number,''))) > 0 OR position(lower(s) in lower(coalesce(dn.main_brand,''))) > 0 OR position(lower(s) in lower(coalesce(dn.model,''))) > 0 OR position(lower(s) in lower(coalesce(qi.vin,''))) > 0)
    ) cnt;

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
        coalesce(inv.invoice_number, dn.invoice_number) AS invoice_number,
        inv.invoice_url,
        d.signature AS delivery_signature,
        d.signature_uuid AS delivery_signature_uuid,
        ud.user_name AS delivery_signature_name,
        ud.email AS delivery_signature_email,
        ld_status.list_data AS status
      FROM qvm_new_apps.delivery_notes dn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = dn.confirmed_item_id
        JOIN qvm_new_apps.delivery_items di ON di.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.deliveries d ON d.delivery_id = di.delivery_id
        LEFT JOIN qvm_new_apps.invoices inv ON inv.invoice_id = di.invoice_id
        LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = d.signature_uuid
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice','pending credit note','invoice issued','credit note issued','settled','claim sent','return request','return'
        )
        AND (p_date_from IS NULL OR d.delivery_date >= p_date_from)
        AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
        AND (v_is_internal OR (v_user_role = 170 AND cb.list_data_id = v_company) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
        AND (NOT v_is_internal OR (p_company_id IS NULL OR cb.list_data_id = p_company_id))
        AND (NOT v_is_internal OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id))
        AND (s = '' OR position(lower(s) in lower(coalesce(dn.order_number,''))) > 0 OR position(lower(s) in lower(coalesce(dn.plate_number,''))) > 0 OR position(lower(s) in lower(coalesce(dn.main_brand,''))) > 0 OR position(lower(s) in lower(coalesce(dn.model,''))) > 0 OR position(lower(s) in lower(coalesce(qi.vin,''))) > 0)
      ORDER BY d.delivery_date DESC NULLS LAST
      LIMIT lim OFFSET off
    ) t;
  ELSE
    dn_rows := '[]'::json;
  END IF;

  IF typ <> 'dn' THEN
    SELECT count(*) INTO rn_count
    FROM (
      SELECT rn.confirmed_item_id
      FROM qvm_new_apps.return_notes rn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = rn.confirmed_item_id
        JOIN qvm_new_apps.return_items ri ON ri.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.returns r ON r.return_id = ri.return_id
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice','pending credit note','invoice issued','credit note issued','settled','claim sent','return request','return'
        )
        AND (p_date_from IS NULL OR r.return_date >= p_date_from)
        AND (p_date_to IS NULL OR r.return_date <= p_date_to)
        AND (v_is_internal OR (v_user_role = 170 AND cb.list_data_id = v_company) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
        AND (NOT v_is_internal OR (p_company_id IS NULL OR cb.list_data_id = p_company_id))
        AND (NOT v_is_internal OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id))
        AND (s = '' OR position(lower(s) in lower(coalesce(rn.order_number,''))) > 0 OR position(lower(s) in lower(coalesce(rn.plate_number,''))) > 0 OR position(lower(s) in lower(coalesce(rn.main_brand,''))) > 0 OR position(lower(s) in lower(coalesce(rn.model,''))) > 0 OR position(lower(s) in lower(coalesce(qi.vin,''))) > 0)
    ) cnt;

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
        coalesce(cn.creditnote_number, rn.creditnote_number) AS creditnote_number,
        cn.creditnote_url,
        r.signature AS return_signature,
        r.signature_uuid AS return_signature_uuid,
        uru.user_name AS return_signature_name,
        uru.email AS return_signature_email,
        ld_status.list_data AS status
      FROM qvm_new_apps.return_notes rn
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = rn.confirmed_item_id
        JOIN qvm_new_apps.return_items ri ON ri.confirmed_item_id = ci.confirmed_item_id
        JOIN qvm_new_apps.returns r ON r.return_id = ri.return_id
        LEFT JOIN qvm_new_apps.creditnote_items cni ON cni.confirmed_item_id = ci.confirmed_item_id
        LEFT JOIN qvm_new_apps.creditnotes cn ON cn.creditnote_id = cni.creditnote_id
        LEFT JOIN qvm_new_apps.user_data uru ON uru.user_id = r.signature_uuid
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
        LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
        LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
      WHERE ld_status.list_data IS NOT NULL
        AND lower(ld_status.list_data) IN (
          'pending invoice','pending credit note','invoice issued','credit note issued','settled','claim sent','return request','return'
        )
        AND (p_date_from IS NULL OR r.return_date >= p_date_from)
        AND (p_date_to IS NULL OR r.return_date <= p_date_to)
        AND (v_is_internal OR (v_user_role = 170 AND cb.list_data_id = v_company) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
        AND (NOT v_is_internal OR (p_company_id IS NULL OR cb.list_data_id = p_company_id))
        AND (NOT v_is_internal OR (p_branch_id IS NULL OR cb.customer_id = p_branch_id))
        AND (s = '' OR position(lower(s) in lower(coalesce(rn.order_number,''))) > 0 OR position(lower(s) in lower(coalesce(rn.plate_number,''))) > 0 OR position(lower(s) in lower(coalesce(rn.main_brand,''))) > 0 OR position(lower(s) in lower(coalesce(rn.model,''))) > 0 OR position(lower(s) in lower(coalesce(qi.vin,''))) > 0)
      ORDER BY r.return_date DESC NULLS LAST
      LIMIT lim OFFSET off
    ) t;
  ELSE
    rn_rows := '[]'::json;
  END IF;

  RETURN json_build_object(
    'dn', coalesce(dn_rows, '[]'::json),
    'rn', coalesce(rn_rows, '[]'::json),
    'dn_count', dn_count,
    'rn_count', rn_count
  );
END;
$function$;;
