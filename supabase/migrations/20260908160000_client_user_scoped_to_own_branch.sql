-- A client user sees their own branch, not their whole company.
--
-- The access predicate on every client-facing dashboard read:
--     v_user_role = 170 AND EXISTS (... cb.list_data_id = v_company AND cb.customer_id = qi.customer_id)
-- so a Client Admin saw every branch of their company, while every other client role was already
-- limited to its own branch one clause below. The workshop is a Client Admin, and should see only
-- what its own branch raised: user_data.user_branch = quotation_items.customer_id.
--
-- The edit is deliberately the smallest one that says that. Each company match becomes a branch
-- match on the same alias, so the clause reads
--     cb.customer_id = v_user_branch AND cb.customer_id = qi.customer_id
-- and the structure, the joins and the internal-user short circuit above it are all untouched.
-- Internal users are unaffected: `v_is_internal OR ...` still wins before any of this is reached.
--
-- Live, company 1 has two branches and the difference is real: 46 quotations company-wide against
-- 38 for branch 121, so the 8 raised by الدمام correctly stop appearing for a فرع الخبر user.
--
-- Not touched, because company is the right scope there: list_my_company_branches (it feeds the
-- branch picker), customer_statement, get_notification_settings and payment_record.

CREATE OR REPLACE FUNCTION public.get_archive_note_rows(p_user_id uuid, p_search text DEFAULT NULL::text, p_type text DEFAULT 'all'::text, p_company_id integer DEFAULT NULL::integer, p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
          OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
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
          OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
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
$function$;

CREATE OR REPLACE FUNCTION public.get_archive_note_rows(p_user_id uuid, p_search text DEFAULT NULL::text, p_type text DEFAULT 'all'::text, p_company_id integer DEFAULT NULL::integer, p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
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
        AND (v_is_internal OR (v_user_role = 170 AND cb.customer_id = v_user_branch) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
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
        AND (v_is_internal OR (v_user_role = 170 AND cb.customer_id = v_user_branch) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
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
        AND (v_is_internal OR (v_user_role = 170 AND cb.customer_id = v_user_branch) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
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
        AND (v_is_internal OR (v_user_role = 170 AND cb.customer_id = v_user_branch) OR (v_user_role != 170 AND cb.customer_id = v_user_branch))
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
$function$;

CREATE OR REPLACE FUNCTION public.get_confirmed_orders_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'desc'::text, p_branch_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  WITH base_orders AS (
    SELECT
      co.confirmed_order_id,
      q.quotation_id,
      q.order_number,
      q.created_at,
      co.created_at AS confirmationDate,
      q.plate_number,
      vehicle_info.vin,
      status_info.status AS order_status,
      b.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      b.customer_id AS branch_id,
      b.branch_name,
      q.insurance_company_id,
      ic.name AS insurance_company_name,
      ld_delivery.list_data AS delivery_type,
      ld_order_type.list_data AS order_type,
      u.user_name AS service_advisor,
      q.service_advisor AS service_advisor_id,
      q.shipping_price,
      vehicle_info.main_brand,
      vehicle_info.model,
      vehicle_info.year,
      items_meta.total_value,
      items_meta.item_count,
      co.created_at AS sort_created_at,
      items_meta.total_value AS sort_total_value
    FROM qvm_new_apps.confirmed_orders co
      LEFT JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
      LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
      LEFT JOIN qvm_new_apps.list_data ld_order_type ON ld_order_type.list_data_id = q.order_type
      LEFT JOIN LATERAL (
        SELECT qi.customer_id AS customer_id
        FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC
        LIMIT 1
      ) first_branch ON true
      LEFT JOIN qvm_new_apps.client_branches b ON b.customer_id = first_branch.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = b.list_data_id
      LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = q.insurance_company_id
      LEFT JOIN LATERAL (
        SELECT
          ci2.item_status as item_status_id,
          ldc.list_data AS status,
          CASE
            WHEN p_status IS NULL THEN true
            ELSE EXISTS (
              SELECT 1
              FROM qvm_new_apps.confirmed_items ci_check
              WHERE ci_check.confirmed_order_id = co.confirmed_order_id
                AND ci_check.item_status = p_status::integer
            )
          END as has_filtered_status
        FROM qvm_new_apps.confirmed_items ci2
        LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ci2.item_status
        WHERE ci2.confirmed_order_id = co.confirmed_order_id
        ORDER BY ci2.confirmed_item_id ASC
        LIMIT 1
      ) status_info ON true
      LEFT JOIN LATERAL (
        SELECT
          qi3.vin AS vin,
          ld_brand.list_data AS main_brand,
          qi3.model AS model,
          qi3.year AS year
        FROM qvm_new_apps.quotation_items qi3
        LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
        WHERE qi3.quotation_id = q.quotation_id
        ORDER BY qi3.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
      LEFT JOIN LATERAL (
        SELECT
          COALESCE(
            SUM(
              (qi.total_price_before_vat::numeric) * (1 - COALESCE(qi.discount_percent, 0) / 100)
            ),
            0
          ) AS total_value,
          COUNT(*)::int AS item_count
        FROM qvm_new_apps.confirmed_items ci
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        WHERE ci.confirmed_order_id = co.confirmed_order_id
          AND (
            v_is_internal
            OR (
              v_user_role = 170
              AND EXISTS (
                SELECT 1
                FROM qvm_new_apps.client_branches cb2
                WHERE cb2.customer_id = v_user_branch
                  AND cb2.customer_id = qi.customer_id
              )
            )
            OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
          )
      ) items_meta ON true
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND status_info.has_filtered_status = true
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            WHERE cb.customer_id = v_user_branch
              AND cb.customer_id = first_branch.customer_id
          )
        )
        OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
      )
      AND (NOT v_is_internal OR p_branch_id IS NULL OR first_branch.customer_id = p_branch_id)
      AND items_meta.item_count > 0
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR vehicle_info.vin ILIKE '%' || p_search || '%'
        OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          LEFT JOIN qvm_new_apps.confirmed_items cis ON cis.quotation_item_id = qis.quotation_item_id
          WHERE cis.confirmed_order_id = co.confirmed_order_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
            )
        )
      )
  ),
  paged_orders AS (
    SELECT *
    FROM base_orders
    ORDER BY
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN sort_total_value END ASC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN sort_total_value END DESC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN sort_created_at END ASC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN sort_created_at END DESC,
      sort_created_at DESC
    LIMIT p_limit
    OFFSET p_offset
  ),
  orders_with_details AS (
    SELECT
      jsonb_build_object(
        'confirmed_order_id', po.confirmed_order_id::text,
        'order_number', po.order_number,
        'created_at', po.created_at,
        'confirmationDate', po.confirmationDate,
        'plateNumber', po.plate_number,
        'vin', po.vin,
        'order_status', po.order_status,
        'client_company_id', po.client_company_id,
        'client_company', po.client_company,
        'branch_id', po.branch_id,
        'branch_name', po.branch_name,
        'insurance_company_id', po.insurance_company_id,
        'insurance_company_name', po.insurance_company_name,
        'delivery_type', po.delivery_type,
        'order_type', po.order_type,
        'service_advisor', po.service_advisor,
        'service_advisor_id', po.service_advisor_id,
        'shipping_price', po.shipping_price,
        'main_brand', po.main_brand,
        'model', po.model,
        'year', po.year,
        'total_value', po.total_value,
        'item_count', po.item_count
      ) AS order_data,
      po.sort_created_at,
      po.sort_total_value
    FROM paged_orders po
  ),
  items_cte AS (
    SELECT
      ci.confirmed_order_id,
      jsonb_agg(
        jsonb_build_object(
          'confirmed_item_id', ci.confirmed_item_id::text,
          'quotation_item_id', ci.quotation_item_id,
          'part_number', COALESCE(ci.final_part_number, qi.part_number),
          'final_part_number', ci.final_part_number,
          'part_description', qi.part_description,
          'brand_class', ld_orig_brand.list_data,
          'approved_qty', ci.approved_qty,
          'requested_qty', qi.quantity,
          'final_brand_class', ld_brand.list_data,
          'unit_price', qi.price_before_vat,
          'discounted_price', (qi.total_price_before_vat::numeric) * (1 - COALESCE(qi.discount_percent, 0) / 100),
          'discount_percent', qi.discount_percent,
          'agency_price', qi.agency_price,
          'agency_percentage', null,
          'total_price_before_vat', qi.total_price_before_vat,
          'status', ldc.list_data,
          'status_id', ci.item_status,
          'part_photo', qi.part_photo,
          'item_notes_count', (
            SELECT COUNT(*)::int
            FROM qvm_new_apps.notes n
            WHERE n.note_type = 'quotation_item'
              AND n.type_id = qi.quotation_item_id
          )
        ) ORDER BY ci.confirmed_item_id ASC
      ) FILTER (WHERE ci.confirmed_item_id IS NOT NULL) AS items
    FROM qvm_new_apps.confirmed_items ci
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = COALESCE(ci.final_brand_class, qi.brand_class)
    LEFT JOIN qvm_new_apps.list_data ld_orig_brand ON ld_orig_brand.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ldc ON ldc.list_data_id = ci.item_status
    WHERE ci.confirmed_order_id IN (SELECT confirmed_order_id FROM paged_orders)
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb2
            WHERE cb2.customer_id = v_user_branch
              AND cb2.customer_id = qi.customer_id
          )
        )
        OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
      )
    GROUP BY ci.confirmed_order_id
  ),
  counts AS (
    SELECT count(*)::int AS total_count
    FROM base_orders
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'data', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'order', owd.order_data,
        'items', COALESCE(i.items, '[]'::jsonb)
      ) ORDER BY
        CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN owd.sort_total_value END ASC,
        CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN owd.sort_total_value END DESC,
        CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN owd.sort_created_at END ASC,
        CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN owd.sort_created_at END DESC,
        owd.sort_created_at DESC
      )
      FROM orders_with_details owd
      LEFT JOIN items_cte i ON i.confirmed_order_id = (owd.order_data->>'confirmed_order_id')::bigint
    ), '[]'::jsonb),
    'total_count', (SELECT total_count FROM counts)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_delivered_orders_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_company_id integer DEFAULT NULL::integer, p_branch_id integer DEFAULT NULL::integer, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'event_date'::text, p_sort_order text DEFAULT 'desc'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
    INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  WITH dn_items_agg AS (
    SELECT
      di.delivery_id,
      qi.customer_id AS branch_id,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty), 0) AS total_before_vat,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty * 1.15), 0) AS total_with_vat,
      COALESCE(SUM(qi.price_before_vat * di.delivered_qty * 0.15), 0) AS vat_amount,
      MAX(CASE WHEN ci.item_status NOT IN (28, 29, 30, 214, 215) THEN ci.item_status END) AS base_item_status_id,
      MAX(CASE WHEN ci.item_status NOT IN (28, 29, 30, 214, 215) THEN ld_status.list_data END) AS base_item_status_label,
      MAX(ci.item_status) AS fallback_item_status_id,
      MAX(ld_status.list_data) AS fallback_item_status_label,
      BOOL_OR(ci.item_status IN (213, 25)) AS has_pending_item_status,
      BOOL_OR(di.invoice_id IS NOT NULL) AS has_invoice
    FROM qvm_new_apps.delivery_items di
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    GROUP BY di.delivery_id, qi.customer_id
  ),
  dn_base AS (
    SELECT DISTINCT ON (d.delivery_id, cb.customer_id)
      'DN'::text AS note_type,
      d.delivery_id::text AS note_id,
      q.order_number,
      co.created_at AS order_date,
      d.client_po,
      d.delivery_date AS event_date,
      q.plate_number,
      vehicle_info.vin,
      vehicle_info.brand,
      vehicle_info.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      d.signature,
      d.signature_uuid,
      u.user_name AS signed_by,
      inv.invoice_number,
      d.shipping_price,
      q.shipping_type,
      dia.total_before_vat,
      dia.total_with_vat,
      dia.vat_amount,
      COALESCE(dia.base_item_status_id, dia.fallback_item_status_id) AS item_status_id,
      COALESCE(dia.base_item_status_label, dia.fallback_item_status_label) AS item_status_label,
      dia.has_pending_item_status,
      dia.has_invoice
    FROM qvm_new_apps.deliveries d
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = d.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.delivery_items di ON di.delivery_id = d.delivery_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = di.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN dn_items_agg dia ON dia.delivery_id = d.delivery_id AND dia.branch_id = cb.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = d.signature_uuid
      LEFT JOIN LATERAL (
        SELECT i.invoice_number
        FROM qvm_new_apps.invoices i
        WHERE i.confirmed_order_id = co.confirmed_order_id
        ORDER BY i.created_at DESC
        LIMIT 1
      ) inv ON true
      LEFT JOIN LATERAL (
        SELECT
          qi2.vin AS vin,
          ld_brand2.list_data AS brand,
          qi2.model AS model
        FROM qvm_new_apps.quotation_items qi2
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        WHERE qi2.quotation_id = q.quotation_id
          AND qi2.customer_id = cb.customer_id
        ORDER BY qi2.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
    WHERE
      (p_date_from IS NULL OR d.delivery_date >= p_date_from)
      AND (p_date_to IS NULL OR d.delivery_date <= p_date_to)
      AND (
        v_is_internal
        OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
    ORDER BY d.delivery_id, cb.customer_id
  ),
  rn_items_agg AS (
    SELECT
      ri.return_id,
      qi.customer_id AS branch_id,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty), 0) AS total_before_vat,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty * 1.15), 0) AS total_with_vat,
      COALESCE(SUM(qi.price_before_vat * ri.return_qty * 0.15), 0) AS vat_amount,
      MAX(ci.item_status) AS item_status_id,
      MAX(ld_status.list_data) AS item_status_label,
      BOOL_OR(ci.item_status IN (214, 215)) AS has_pending_item_status,
      BOOL_OR(ri.creditnote_id IS NOT NULL) AS has_creditnote
    FROM qvm_new_apps.return_items ri
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_status ON ld_status.list_data_id = ci.item_status
    GROUP BY ri.return_id, qi.customer_id
  ),
  rn_base AS (
    SELECT DISTINCT ON (r.return_id, cb.customer_id)
      'RN'::text AS note_type,
      r.return_id::text AS note_id,
      q.order_number,
      co.created_at AS order_date,
      r.referenced_client_po,
      r.return_date::timestamp with time zone AS event_date,
      q.plate_number,
      vehicle_info.vin,
      vehicle_info.brand,
      vehicle_info.model,
      cb.list_data_id AS client_company_id,
      ld_company.list_data AS client_company,
      cb.customer_id AS branch_id,
      cb.branch_name,
      r.signature,
      r.signature_uuid,
      u.user_name AS signed_by,
      cr.creditnote_number,
      r.shipping_price,
      q.shipping_type,
      ria.total_before_vat,
      ria.total_with_vat,
      ria.vat_amount,
      ria.item_status_id,
      ria.item_status_label,
      ria.has_pending_item_status,
      ria.has_creditnote
    FROM qvm_new_apps.returns r
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = r.confirmed_order_id
      JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
      JOIN qvm_new_apps.return_items ri ON ri.return_id = r.return_id
      JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = ri.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
      LEFT JOIN rn_items_agg ria ON ria.return_id = r.return_id AND ria.branch_id = cb.customer_id
      LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = cb.list_data_id
      LEFT JOIN qvm_new_apps.user_data u ON u.user_id = r.signature_uuid
      LEFT JOIN LATERAL (
        SELECT c.creditnote_number
        FROM qvm_new_apps.creditnotes c
        WHERE c.confirmed_order_id = co.confirmed_order_id
        ORDER BY c.created_at DESC
        LIMIT 1
      ) cr ON true
      LEFT JOIN LATERAL (
        SELECT
          qi2.vin AS vin,
          ld_brand2.list_data AS brand,
          qi2.model AS model
        FROM qvm_new_apps.quotation_items qi2
        LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
        WHERE qi2.quotation_id = q.quotation_id
          AND qi2.customer_id = cb.customer_id
        ORDER BY qi2.quotation_item_id ASC
        LIMIT 1
      ) vehicle_info ON true
    WHERE
      (p_date_from IS NULL OR r.return_date >= p_date_from)
      AND (p_date_to IS NULL OR r.return_date <= p_date_to)
      AND (
        v_is_internal
        OR (v_user_role = 170 AND cb.customer_id = v_user_branch)
        OR (v_user_role != 170 AND cb.customer_id = v_user_branch)
      )
    ORDER BY r.return_id, cb.customer_id
  ),
  combined AS (
    SELECT
      note_type,
      note_id,
      order_number,
      order_date,
      client_po,
      event_date,
      plate_number,
      vin,
      brand,
      model,
      client_company_id,
      client_company,
      branch_id,
      branch_name,
      signature,
      signature_uuid,
      signed_by,
      invoice_number,
      NULL::text AS creditnote_number,
      shipping_price,
      shipping_type,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_invoice AS has_doc,
      item_status_id,
      COALESCE(
        item_status_label,
        CASE
          WHEN (signature IS NULL OR signature = '') THEN 'DN Sign Pending'
          WHEN NOT has_invoice THEN 'Pending Invoice'
          ELSE 'Invoice Issued'
        END
      ) AS status
    FROM dn_base
    UNION ALL
    SELECT
      note_type,
      note_id,
      order_number,
      order_date,
      referenced_client_po,
      event_date,
      plate_number,
      vin,
      brand,
      model,
      client_company_id,
      client_company,
      branch_id,
      branch_name,
      signature,
      signature_uuid,
      signed_by,
      NULL::text AS invoice_number,
      creditnote_number,
      shipping_price,
      shipping_type,
      total_before_vat,
      total_with_vat,
      vat_amount,
      has_pending_item_status,
      has_creditnote AS has_doc,
      item_status_id,
      COALESCE(
        item_status_label,
        CASE
          WHEN (signature IS NULL OR signature = '') THEN 'RN Sign Pending'
          WHEN NOT has_creditnote THEN 'Pending Credit Note'
          ELSE 'Credit Note Issued'
        END
      ) AS status
    FROM rn_base
  ),
  filtered AS (
    SELECT *
    FROM combined
    WHERE
      (p_status IS NULL OR status = p_status)
      AND (
        (note_type = 'DN' AND (
          item_status_id IN (25, 213)
          OR (
            item_status_id = 26
            AND (signature IS NULL OR signature = '' OR NOT has_doc)
          )
        ))
        OR (note_type = 'RN' AND (
          item_status_id IN (214, 215)
          OR (
            item_status_id = 30
            AND (signature IS NULL OR signature = '' OR NOT has_doc)
          )
        ))
      )
      AND (
        p_search IS NULL
        OR order_number ILIKE '%' || p_search || '%'
        OR plate_number ILIKE '%' || p_search || '%'
        OR vin ILIKE '%' || p_search || '%'
        OR brand ILIKE '%' || p_search || '%'
        OR model ILIKE '%' || p_search || '%'
      )
      AND (
        NOT v_is_internal
        OR (p_company_id IS NULL OR client_company_id = p_company_id)
      )
      AND (
        NOT v_is_internal
        OR (p_branch_id IS NULL OR branch_id = p_branch_id)
      )
  ),
  paged AS (
    SELECT *
    FROM filtered
    ORDER BY
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'asc' THEN COALESCE(event_date, order_date) END ASC,
      CASE WHEN p_sort_by = 'event_date' AND p_sort_order = 'desc' THEN COALESCE(event_date, order_date) END DESC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'asc' THEN total_before_vat END ASC,
      CASE WHEN p_sort_by = 'total_value' AND p_sort_order = 'desc' THEN total_before_vat END DESC,
      COALESCE(event_date, order_date) DESC,
      note_id DESC
    LIMIT p_limit
    OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Delivered notes fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered),
    'data',
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', note_id,
            'type', note_type,
            'status', status,
            'orderNumber', order_number,
            'orderDate', order_date,
            'poNumber', client_po,
            'eventDate', event_date,
            'plateNumber', plate_number,
            'vin', vin,
            'brand', brand,
            'model', model,
            'client', client_company,
            'branch', branch_name,
            'totalBeforeVat', COALESCE(dn_items.total_before_vat, rn_items.total_before_vat, 0),
            'vatAmount', COALESCE(dn_items.vat_amount, rn_items.vat_amount, 0),
            'totalWithVat', COALESCE(dn_items.total_with_vat, rn_items.total_with_vat, 0),
            'shippingFees', COALESCE(shipping_price, 0),
            'shippingType', shipping_type,
            'signature', signature,
            'signedBy', signed_by,
            'signedAt', NULL,
            'invoiceNumber', invoice_number,
            'creditNoteNumber', creditnote_number,
            'items', COALESCE(dn_items.items, rn_items.items, '[]'::jsonb)
          )
        ),
        '[]'::jsonb
      )
  )
  INTO v_result
  FROM paged
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'id', ci2.confirmed_item_id::text,
              'partNumber', qi2.part_number,
              'description', qi2.part_description,
              'brand', ld_brand2.list_data,
              'brandClass', ld_brand_class2.list_data,
              'quantity', di2.delivered_qty,
              'priceBeforeVat', qi2.price_before_vat,
              'totalWithVat', (qi2.price_before_vat * di2.delivered_qty * 1.15),
              'vatAmount', (qi2.price_before_vat * di2.delivered_qty * 0.15)
            )
            ORDER BY di2.delivery_item_id
          ),
          '[]'::jsonb
        ) AS items,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty), 0) AS total_before_vat,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty * 1.15), 0) AS total_with_vat,
        COALESCE(SUM(qi2.price_before_vat * di2.delivered_qty * 0.15), 0) AS vat_amount
      FROM qvm_new_apps.delivery_items di2
      JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = di2.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
      LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
      WHERE di2.delivery_id = paged.note_id::integer
        AND qi2.customer_id = paged.branch_id
        AND paged.note_type = 'DN'
    ) dn_items ON paged.note_type = 'DN'
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'id', ci2.confirmed_item_id::text,
              'partNumber', qi2.part_number,
              'description', qi2.part_description,
              'brand', ld_brand2.list_data,
              'brandClass', ld_brand_class2.list_data,
              'quantity', ri2.return_qty,
              'priceBeforeVat', qi2.price_before_vat,
              'totalWithVat', (qi2.price_before_vat * ri2.return_qty * 1.15),
              'vatAmount', (qi2.price_before_vat * ri2.return_qty * 0.15)
            )
            ORDER BY ri2.return_item_id
          ),
          '[]'::jsonb
        ) AS items,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty), 0) AS total_before_vat,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty * 1.15), 0) AS total_with_vat,
        COALESCE(SUM(qi2.price_before_vat * ri2.return_qty * 0.15), 0) AS vat_amount
      FROM qvm_new_apps.return_items ri2
      JOIN qvm_new_apps.confirmed_items ci2 ON ci2.confirmed_item_id = ri2.confirmed_item_id
      JOIN qvm_new_apps.quotation_items qi2 ON qi2.quotation_item_id = ci2.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi2.main_brand
      LEFT JOIN qvm_new_apps.list_data ld_brand_class2 ON ld_brand_class2.list_data_id = qi2.brand_class
      WHERE ri2.return_id = paged.note_id::bigint
        AND qi2.customer_id = paged.branch_id
        AND paged.note_type = 'RN'
    ) rn_items ON paged.note_type = 'RN';

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_overall_order_summary(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH
  user_ctx AS (
    SELECT
      ud.user_company AS company,
      ud.user_branch AS user_branch,
      ud.user_role AS user_role,
      ud.user_type AS user_type,
      (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud
    WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id, first_branch.customer_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  per_order AS (
    SELECT
      os.confirmed_order_id,
      BOOL_OR(ci.item_status = 19) AS any_confirmed,
      BOOL_OR(ci.item_status = 23) AS any_delivered,
      BOOL_OR(ci.item_status = 28) AS any_return_requests,
      BOOL_OR(ci.item_status = 24) AS any_cancellation_requests,
      BOOL_OR(ci.item_status = 21) AS any_processing
    FROM order_scope os
    LEFT JOIN qvm_new_apps.confirmed_items ci
      ON ci.confirmed_order_id = os.confirmed_order_id
    GROUP BY os.confirmed_order_id
  ),
  po_missing AS (
    SELECT DISTINCT os.confirmed_order_id
    FROM order_scope os
    LEFT JOIN qvm_new_apps.purchase_orders po
      ON po.confirmed_order_id = os.confirmed_order_id
    WHERE
      (coalesce(nullif(trim(po.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(po.zoho_bill_url), ''), null) IS NULL)
  ),
  rfq_scope AS (
    SELECT DISTINCT q.quotation_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE
      uc.is_internal
      OR (
        uc.user_role = 170 AND EXISTS (
          SELECT 1 FROM qvm_new_apps.client_branches cb
          WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (
        uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch
      )
  ),
  rfq_items AS (
    SELECT qi.quotation_id, qi.item_status
    FROM qvm_new_apps.quotation_items qi
    JOIN rfq_scope rs ON rs.quotation_id = qi.quotation_id
  ),
  rfq_counts AS (
    SELECT
      COUNT(DISTINCT CASE WHEN item_status IN (15, 235, 236) THEN quotation_id END) AS new_rfq,
      COUNT(DISTINCT CASE WHEN item_status IN (16, 237) THEN quotation_id END) AS processing_rfq,
      COUNT(DISTINCT CASE WHEN item_status = 17 THEN quotation_id END) AS priced
    FROM rfq_items
  ),
  order_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE any_confirmed) AS confirmed,
      COUNT(*) FILTER (WHERE any_delivered) AS delivered,
      COUNT(*) FILTER (WHERE any_return_requests) AS return_requests,
      COUNT(*) FILTER (WHERE any_cancellation_requests) AS cancellation_requests,
      COUNT(*) FILTER (WHERE any_processing) AS processing_order
    FROM per_order
  ),
  missing_po AS (
    SELECT COUNT(*) AS missing_purchase_invoices
    FROM po_missing
  )
  SELECT jsonb_build_object(
    'new_rfq', coalesce((SELECT new_rfq FROM rfq_counts),0),
    'processing', coalesce((SELECT processing_rfq FROM rfq_counts),0) + coalesce((SELECT processing_order FROM order_counts),0),
    'priced', coalesce((SELECT priced FROM rfq_counts),0),
    'confirmed', coalesce((SELECT confirmed FROM order_counts),0),
    'delivered', coalesce((SELECT delivered FROM order_counts),0),
    'return_requests', coalesce((SELECT return_requests FROM order_counts),0),
    'cancellation_requests', coalesce((SELECT cancellation_requests FROM order_counts),0),
    'missing_purchase_invoices', coalesce((SELECT missing_purchase_invoices FROM missing_po),0)
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_counters(p_user_id uuid, p_is_manager boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, ud.user_type AS user_type, (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
      OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
      OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  latest_po_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    ORDER BY pi.confirmed_item_id, po.created_at DESC
  ),
  latest_vcn_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    ORDER BY pi.confirmed_item_id, vcn.created_at DESC
  ),
  item_scope AS (
    SELECT ci.confirmed_item_id, co.confirmed_order_id, qi.customer_id, qi.cost_id, qvi.vendor_id, q.account_manager
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    JOIN user_ctx uc ON true
  ),
  po_missing AS (
    SELECT DISTINCT is_.confirmed_item_id
    FROM item_scope is_
    LEFT JOIN latest_po_by_item lpo ON lpo.confirmed_item_id = is_.confirmed_item_id
    WHERE (coalesce(nullif(trim(lpo.vendor_invoice_url), ''), null) IS NULL)
      AND (coalesce(nullif(trim(lpo.vendor_invoice_number), ''), null) IS NULL)
      AND (coalesce(nullif(trim(lpo.zoho_bill_url), ''), null) IS NULL)
  ),
  rn_missing AS (
    SELECT DISTINCT is_.confirmed_item_id
    FROM item_scope is_
    LEFT JOIN latest_vcn_by_item lvcn ON lvcn.confirmed_item_id = is_.confirmed_item_id
    WHERE lvcn.confirmed_item_id IS NULL
  )
  SELECT jsonb_build_object(
    'missing_purchase_invoices', (SELECT COUNT(*) FROM po_missing),
    'missing_return_invoices', (SELECT COUNT(*) FROM rn_missing)
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false, p_account_manager uuid DEFAULT NULL::uuid, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 200, p_offset integer DEFAULT 0, p_purchase_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_delivered_ids int[];
  result jsonb;
BEGIN
  SELECT COALESCE(array_agg(list_data_id), ARRAY[]::int[]) INTO v_delivered_ids
  FROM qvm_new_apps.list_data WHERE lower(list_data) LIKE 'deliver%';

  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, ud.user_type AS user_type, (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id, q.quotation_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  latest_po_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      po.purchase_order_id,
      po.vendor_invoice_url,
      po.vendor_invoice_number,
      po.zoho_bill_url,
      po.uploaded_by AS invoice_uploaded_by
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    ORDER BY pi.confirmed_item_id, po.created_at DESC
  ),
  latest_vcn_by_item AS (
    SELECT DISTINCT ON (pi.confirmed_item_id)
      pi.confirmed_item_id,
      vcn.vendor_creditnote_url,
      vcn.uploaded_by AS creditnote_uploaded_by
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    ORDER BY pi.confirmed_item_id, vcn.created_at DESC
  ),
  attachments_per_item AS (
    SELECT pi.confirmed_item_id, COALESCE(array_agg(pia.file_url ORDER BY pia.uploaded_at DESC), ARRAY[]::text[]) AS invoice_attachments
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.purchase_invoice_attachments pia ON pia.purchase_order_id = po.purchase_order_id
    GROUP BY pi.confirmed_item_id
  ),
  vcn_attachments_per_item AS (
    SELECT pi.confirmed_item_id, COALESCE(array_agg(vcn.vendor_creditnote_url ORDER BY vcn.created_at DESC), ARRAY[]::text[]) AS vendor_creditnote_attachments
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.vendor_creditnotes vcn ON vcn.purchase_order_id = po.purchase_order_id
    GROUP BY pi.confirmed_item_id
  ),
  latest_delivered AS (
    SELECT confirmed_item_id, status_changed_by
    FROM (
      SELECT sl.confirmed_item_id, sl.status_changed_by,
             row_number() OVER (PARTITION BY sl.confirmed_item_id ORDER BY sl.created_at DESC) AS rn
      FROM qvm_new_apps.status_logs sl
      WHERE sl.item_status = ANY (v_delivered_ids)
    ) d WHERE rn = 1
  ),
  base AS (
    SELECT
      ci.confirmed_item_id,
      co.confirmed_order_id,
      ci.quotation_item_id,
      q.order_number,
      q.created_at AS rfq_date,
      co.created_at AS confirmation_date,
      q.account_manager,
      qi.customer_id,
      cb.branch_name,
      qi.model,
      ldb.list_data AS main_brand,
      qi.part_description,
      ci.final_part_number,
      ldf.list_data AS final_brand_class,
      ci.approved_qty,
      qvi.cost AS purchase_cost,
      qvi.vendor_id,
      vnd.vendor_name,
      lpo.purchase_order_id,
      lpo.vendor_invoice_url,
      lpo.vendor_invoice_number,
      lpo.zoho_bill_url,
      lpo.invoice_uploaded_by,
      lvcn.creditnote_uploaded_by,
      lvcn.vendor_creditnote_url,
      ao.invoice_attachments,
      vao.vendor_creditnote_attachments,
      ld.status_changed_by AS delivered_by,
      uc.is_internal AS is_internal_user,
      pit.receipt_status,
      pit.received_qty
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN user_ctx uc ON true
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
    LEFT JOIN qvm_new_apps.list_data ldb ON ldb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data ldf ON ldf.list_data_id = ci.final_brand_class
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = qvi.vendor_id
    LEFT JOIN latest_po_by_item lpo ON lpo.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN latest_vcn_by_item lvcn ON lvcn.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN attachments_per_item ao ON ao.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN vcn_attachments_per_item vao ON vao.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN latest_delivered ld ON ld.confirmed_item_id = ci.confirmed_item_id
    LEFT JOIN qvm_new_apps.purchase_items pit ON pit.confirmed_item_id = ci.confirmed_item_id AND pit.purchase_order_id = lpo.purchase_order_id
  ),
  filtered AS (
    SELECT * FROM base i
    WHERE (s = '' OR position(lower(s) in lower(coalesce(i.order_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_invoice_number, ''))) > 0 OR position(lower(s) in lower(coalesce(i.vendor_name, ''))) > 0 OR position(lower(s) in lower(coalesce(i.final_part_number, ''))) > 0)
      AND (
        CASE
          WHEN p_missing_pi AND p_missing_rn THEN
            (
              (coalesce(nullif(trim(i.vendor_invoice_url), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.vendor_invoice_number), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.zoho_bill_url), ''), null) IS NULL)
            )
            OR
            (
              i.vendor_creditnote_url IS NULL
            )
          ELSE
            (NOT p_missing_pi OR (
              (coalesce(nullif(trim(i.vendor_invoice_url), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.vendor_invoice_number), ''), null) IS NULL)
              AND (coalesce(nullif(trim(i.zoho_bill_url), ''), null) IS NULL)
            ))
            AND (NOT p_missing_rn OR i.vendor_creditnote_url IS NULL)
        END
      )
      AND (p_account_manager IS NULL OR i.account_manager = p_account_manager)
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR i.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR i.vendor_id = ANY(v_supplier_ids))
      AND (p_is_manager OR i.is_internal_user OR i.delivered_by = p_user_id OR i.account_manager = p_user_id)
      AND (p_purchase_order_id IS NULL OR i.purchase_order_id = p_purchase_order_id)
  )
  SELECT jsonb_build_object(
    'status','success',
    'message','OK',
    'total', (SELECT COUNT(*) FROM filtered),
    'orders_total', (SELECT COUNT(DISTINCT confirmed_order_id) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t)) FROM (
        SELECT
          confirmed_item_id,
          confirmed_order_id,
          quotation_item_id,
          order_number,
          rfq_date,
          confirmation_date,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = delivered_by) AS delivered_by_name,
          purchase_order_id,
          vendor_invoice_url,
          vendor_invoice_number,
          zoho_bill_url,
          invoice_attachments,
          vendor_creditnote_url,
          vendor_creditnote_attachments,
          branch_name,
          model,
          main_brand,
          part_description,
          final_part_number,
          final_brand_class,
          approved_qty,
          purchase_cost,
          vendor_name,
          receipt_status,
          received_qty,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = invoice_uploaded_by) AS invoice_uploaded_by_name,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = creditnote_uploaded_by) AS creditnote_uploaded_by_name
        FROM filtered
        ORDER BY coalesce(confirmation_date, rfq_date) DESC, order_number, confirmed_item_id
        LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  )
  INTO result;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rfq_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'RFQs fetched successfully',
    'data', COALESCE(jsonb_agg(r.rq ORDER BY (r.rq->>'created_at')::timestamptz DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_id', q.quotation_id,
      'order_number', q.order_number,
      'plate_number', q.plate_number,
      'created_at', q.created_at,
      'service_advisor', u.user_name,
      'service_advisor_id', q.service_advisor,
      'delivery_type', ld_delivery.list_data,
      'order_type', ld_order.list_data,
      'shipping_price', q.shipping_price,
      'shipping_type', q.shipping_type,
      'discount_amount', NULL,
      'branch_id', b.customer_id,
      'branch_name', b.branch_name,
      'client_company_id', b.list_data_id,
      'client_company', ld_company.list_data,
      'rfq_status', status_info.status,
      'vin', vehicle_info.vin,
      'main_brand', vehicle_info.main_brand,
      'model', vehicle_info.model,
      'year', vehicle_info.year,
      'items', items_info.items,
      'notes_count', COALESCE(notes_info.notes_count, 0)
    ) AS rq
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
    LEFT JOIN LATERAL (
      SELECT qi.customer_id AS customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches b ON b.customer_id = first_branch.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = b.list_data_id
    LEFT JOIN LATERAL (
      -- RFQ status logic: Show RFQ if ANY item matches the status filter
      -- Only use quotation_items status - never confirmed_items status
      -- FIXED: Handle status IDs instead of status names
      SELECT 
        qi2.item_status as item_status_id,
        ldr.list_data AS status,
        CASE 
          WHEN p_status IS NULL THEN true
          ELSE EXISTS (
            SELECT 1
            FROM qvm_new_apps.quotation_items qi_check
            WHERE qi_check.quotation_id = q.quotation_id
              AND qi_check.item_status = p_status::integer  -- FIXED: Compare IDs, not names
          ) 
        END as has_filtered_status
      FROM qvm_new_apps.quotation_items qi2
      LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
      WHERE qi2.quotation_id = q.quotation_id
      ORDER BY qi2.quotation_item_id ASC
      LIMIT 1
    ) status_info ON true
    LEFT JOIN LATERAL (
      SELECT
        qi3.vin AS vin,
        ld_brand.list_data AS main_brand,
        qi3.model AS model,
        qi3.year AS year
      FROM qvm_new_apps.quotation_items qi3
      LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
      WHERE qi3.quotation_id = q.quotation_id
      ORDER BY qi3.quotation_item_id ASC
      LIMIT 1
    ) vehicle_info ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'quotation_item_id', qi.quotation_item_id,
            'part_number', qi.part_number,
            'part_description', qi.part_description,
            'quantity', qi.quantity,
            'brand_class', ld_bc.list_data,
            'alternative_part_number', qi.alternative_part_number,
            'alternative_brand_class', ld_abc.list_data,
            'part_photo', qi.part_photo,
            'delivery_type', ld_delivery.list_data,
            'order_type', ld_order.list_data,
            'estimated_price', qi.estimated_price,
            'price_before_vat', qi.price_before_vat,
            'discount_percent', qi.discount_percent,
            'agency_price', qi.agency_price,
            'total_price_before_vat', qi.total_price_before_vat,
            'final_part_number', ci.final_part_number,
            'approved_qty', ci.approved_qty,
            'sla',qvi.sla,
            'item_status', ldr2.list_data,
            'item_status_id', qi.item_status,
            'vin', qi.vin,
            'main_brand', ld_brand2.list_data,
            'model', qi.model,
            'year', qi.year,
            'branch_id', qi.customer_id,
            'item_notes_count', (
  SELECT COUNT(*)::int
  FROM qvm_new_apps.notes n
  WHERE n.note_type = 'quotation_items'
    AND n.type_id = qi.quotation_item_id
    AND n.is_internal = FALSE
)
          )
          ORDER BY qi.quotation_item_id
        ),
        '[]'::jsonb
      ) AS items
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ldr2 ON ldr2.list_data_id = qi.item_status
      LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
      LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi.main_brand
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
      WHERE qi.quotation_id = q.quotation_id
        AND (
          v_is_internal
          OR (
            v_user_role = 170
            AND EXISTS (
              SELECT 1
              FROM qvm_new_apps.client_branches cb2
              WHERE cb2.customer_id = v_user_branch
                AND cb2.customer_id = qi.customer_id
            )
          )
          OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
        )
    ) items_info ON true
    LEFT JOIN LATERAL (
  SELECT COUNT(*)::int AS notes_count
  FROM qvm_new_apps.notes n
  WHERE n.note_type = 'quotations'
    AND n.type_id = q.quotation_id
    AND n.is_internal = FALSE
) notes_info ON true
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)    -- FIXED: Compare IDs
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)              -- FIXED: Compare IDs
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND status_info.has_filtered_status = true  -- This ensures RFQ appears if ANY item matches the filter
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            WHERE cb.customer_id = v_user_branch
              AND cb.customer_id = first_branch.customer_id
          )
        )
        OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
      )
      AND (jsonb_array_length(items_info.items) > 0)
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR vehicle_info.vin ILIKE '%' || p_search || '%'
        OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
            )
        )
      )
  ) r;

  RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION public.rfq_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'created_at'::text, p_sort_order text DEFAULT 'desc'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
  v_total_count int;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  SELECT COUNT(*)
  INTO v_total_count
  FROM qvm_new_apps.quotations q
  LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
  LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
  LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
  LEFT JOIN LATERAL (
    SELECT qi.customer_id AS customer_id
    FROM qvm_new_apps.quotation_items qi
    WHERE qi.quotation_id = q.quotation_id
    ORDER BY qi.quotation_item_id ASC
    LIMIT 1
  ) first_branch ON true
  LEFT JOIN LATERAL (
    SELECT 
      qi2.item_status as item_status_id,
      ldr.list_data AS status,
      CASE 
        WHEN p_status IS NULL THEN true
        ELSE EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qi_check
          WHERE qi_check.quotation_id = q.quotation_id
            AND qi_check.item_status = p_status::integer
        ) 
      END as has_filtered_status
    FROM qvm_new_apps.quotation_items qi2
    LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
    WHERE qi2.quotation_id = q.quotation_id
    ORDER BY qi2.quotation_item_id ASC
    LIMIT 1
  ) status_info ON true
  LEFT JOIN LATERAL (
    SELECT
      qi3.vin AS vin,
      ld_brand.list_data AS main_brand,
      qi3.model AS model,
      qi3.year AS year
    FROM qvm_new_apps.quotation_items qi3
    LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
    WHERE qi3.quotation_id = q.quotation_id
    ORDER BY qi3.quotation_item_id ASC
    LIMIT 1
  ) vehicle_info ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'quotation_item_id', qi.quotation_item_id,
          'part_number', qi.part_number,
          'part_description', qi.part_description,
          'quantity', qi.quantity,
          'brand_class', ld_bc.list_data,
          'alternative_part_number', qi.alternative_part_number,
          'alternative_brand_class', ld_abc.list_data,
          'part_photo', qi.part_photo,
          'delivery_type', ld_delivery.list_data,
          'order_type', ld_order.list_data,
          'estimated_price', qi.estimated_price,
          'price_before_vat', qi.price_before_vat,
          'discount_percent', qi.discount_percent,
          'agency_price', qi.agency_price,
          'total_price_before_vat', qi.total_price_before_vat,
          'final_part_number', ci.final_part_number,
          'approved_qty', ci.approved_qty,
          'sla',qvi.sla,
          'item_status', ldr2.list_data,
          'item_status_id', qi.item_status,
          'vin', qi.vin,
          'main_brand', ld_brand2.list_data,
          'model', qi.model,
          'year', qi.year,
          'branch_id', qi.customer_id,
          'item_notes_count', (
            SELECT COUNT(*)::int
            FROM qvm_new_apps.notes n
            WHERE n.note_type = 'quotation_items'
              AND n.type_id = qi.quotation_item_id
              AND n.is_internal = FALSE
          )
        )
        ORDER BY qi.quotation_item_id
      ),
      '[]'::jsonb
    ) AS items,
    COALESCE(SUM(qi.price_before_vat * qi.quantity * (1 - COALESCE(qi.discount_percent,0) / 100)), 0) AS total_value
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
    LEFT JOIN qvm_new_apps.list_data ldr2 ON ldr2.list_data_id = qi.item_status
    LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
    LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE qi.quotation_id = q.quotation_id
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb2
            WHERE cb2.customer_id = v_user_branch
              AND cb2.customer_id = qi.customer_id
          )
        )
        OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
      )
  ) items_info ON true
  WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
    AND (p_date_to IS NULL OR q.created_at <= p_date_to)
    AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
    AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
    AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
    AND status_info.has_filtered_status = true
    AND (
      v_is_internal
      OR (
        v_user_role = 170
        AND EXISTS (
          SELECT 1
          FROM qvm_new_apps.client_branches cb
          WHERE cb.customer_id = v_user_branch
            AND cb.customer_id = first_branch.customer_id
        )
      )
      OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
    )
    AND (jsonb_array_length(items_info.items) > 0)
    AND (
      p_search IS NULL
      OR q.order_number ILIKE '%' || p_search || '%'
      OR q.plate_number ILIKE '%' || p_search || '%'
      OR vehicle_info.vin ILIKE '%' || p_search || '%'
      OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
      OR EXISTS (
        SELECT 1
        FROM qvm_new_apps.quotation_items qis
        WHERE qis.quotation_id = q.quotation_id
          AND (
            qis.part_number ILIKE '%' || p_search || '%'
            OR qis.part_description ILIKE '%' || p_search || '%'
          )
      )
    );

  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'RFQs fetched successfully',
    'total_count', v_total_count,
    'data', COALESCE(jsonb_agg(r.rq), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'quotation_id', q.quotation_id,
      'order_number', q.order_number,
      'plate_number', q.plate_number,
      'created_at', q.created_at,
      'service_advisor', u.user_name,
      'service_advisor_id', q.service_advisor,
      'delivery_type', ld_delivery.list_data,
      'order_type', ld_order.list_data,
      'shipping_price', q.shipping_price,
      'shipping_type', q.shipping_type,
      'discount_amount', NULL,
      'branch_id', b.customer_id,
      'branch_name', b.branch_name,
      'client_company_id', b.list_data_id,
      'client_company', ld_company.list_data,
      'rfq_status', status_info.status,
      'vin', vehicle_info.vin,
      'main_brand', vehicle_info.main_brand,
      'model', vehicle_info.model,
      'year', vehicle_info.year,
      'items', items_info.items,
      'notes_count', COALESCE(notes_info.notes_count, 0)
    ) AS rq
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
    LEFT JOIN LATERAL (
      SELECT qi.customer_id AS customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches b ON b.customer_id = first_branch.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = b.list_data_id
    LEFT JOIN LATERAL (
      SELECT 
        qi2.item_status as item_status_id,
        ldr.list_data AS status,
        CASE 
          WHEN p_status IS NULL THEN true
          ELSE EXISTS (
            SELECT 1
            FROM qvm_new_apps.quotation_items qi_check
            WHERE qi_check.quotation_id = q.quotation_id
              AND qi_check.item_status = p_status::integer
          ) 
        END as has_filtered_status
      FROM qvm_new_apps.quotation_items qi2
      LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
      WHERE qi2.quotation_id = q.quotation_id
      ORDER BY qi2.quotation_item_id ASC
      LIMIT 1
    ) status_info ON true
    LEFT JOIN LATERAL (
      SELECT
        qi3.vin AS vin,
        ld_brand.list_data AS main_brand,
        qi3.model AS model,
        qi3.year AS year
      FROM qvm_new_apps.quotation_items qi3
      LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
      WHERE qi3.quotation_id = q.quotation_id
      ORDER BY qi3.quotation_item_id ASC
      LIMIT 1
    ) vehicle_info ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'quotation_item_id', qi.quotation_item_id,
            'part_number', qi.part_number,
            'part_description', qi.part_description,
            'quantity', qi.quantity,
            'brand_class', ld_bc.list_data,
            'alternative_part_number', qi.alternative_part_number,
            'alternative_brand_class', ld_abc.list_data,
            'part_photo', qi.part_photo,
            'delivery_type', ld_delivery.list_data,
            'order_type', ld_order.list_data,
            'estimated_price', qi.estimated_price,
            'price_before_vat', qi.price_before_vat,
            'discount_percent', qi.discount_percent,
            'agency_price', qi.agency_price,
            'total_price_before_vat', qi.total_price_before_vat,
            'final_part_number', ci.final_part_number,
            'approved_qty', ci.approved_qty,
            'sla',qvi.sla,
            'item_status', ldr2.list_data,
            'item_status_id', qi.item_status,
            'vin', qi.vin,
            'main_brand', ld_brand2.list_data,
            'model', qi.model,
            'year', qi.year,
            'branch_id', qi.customer_id,
            'item_notes_count', (
              SELECT COUNT(*)::int
              FROM qvm_new_apps.notes n
              WHERE n.note_type = 'quotation_items'
                AND n.type_id = qi.quotation_item_id
                AND n.is_internal = FALSE
            )
          )
          ORDER BY qi.quotation_item_id
        ),
        '[]'::jsonb
      ) AS items,
      COALESCE(SUM(qi.price_before_vat * qi.quantity * (1 - COALESCE(qi.discount_percent,0) / 100)), 0) AS total_value
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ldr2 ON ldr2.list_data_id = qi.item_status
      LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
      LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi.main_brand
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
      WHERE qi.quotation_id = q.quotation_id
        AND (
          v_is_internal
          OR (
            v_user_role = 170
            AND EXISTS (
              SELECT 1
              FROM qvm_new_apps.client_branches cb2
              WHERE cb2.customer_id = v_user_branch
                AND cb2.customer_id = qi.customer_id
            )
          )
          OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
        )
    ) items_info ON true
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS notes_count
      FROM qvm_new_apps.notes n
      WHERE n.note_type = 'quotations'
        AND n.type_id = q.quotation_id
        AND n.is_internal = FALSE
    ) notes_info ON true
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND status_info.has_filtered_status = true
      AND (
        v_is_internal
        OR (
          v_user_role = 170
          AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            WHERE cb.customer_id = v_user_branch
              AND cb.customer_id = first_branch.customer_id
          )
        )
        OR (v_user_role != 170 AND first_branch.customer_id = v_user_branch)
      )
      AND (jsonb_array_length(items_info.items) > 0)
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR vehicle_info.vin ILIKE '%' || p_search || '%'
        OR vehicle_info.main_brand ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qis
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
            )
        )
      )
    ORDER BY
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN q.created_at END ASC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN q.created_at END DESC,
      CASE WHEN p_sort_by = 'total_price' AND p_sort_order = 'asc' THEN items_info.total_value END ASC,
      CASE WHEN p_sort_by = 'total_price' AND p_sort_order = 'desc' THEN items_info.total_value END DESC
    LIMIT p_limit
    OFFSET p_offset
  ) r;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rfq_dashboard_paged(p_user_id uuid, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_delivery_type text DEFAULT NULL::text, p_order_type text DEFAULT NULL::text, p_service_advisor uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 10, p_offset integer DEFAULT 0, p_sort_by text DEFAULT NULL::text, p_sort_order text DEFAULT NULL::text, p_branch_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_company int;
  v_user_branch int;
  v_user_role int;
  v_user_type int;
  v_is_internal boolean;
  v_result jsonb;
BEGIN
  SELECT user_company, user_branch, user_role, user_type
  INTO v_company, v_user_branch, v_user_role, v_user_type
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  WITH candidates AS (
    SELECT q.quotation_id, q.created_at
    FROM qvm_new_apps.quotations q
    WHERE
      (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_delivery_type IS NULL OR q.delivery_type = p_delivery_type::integer)
      AND (p_order_type IS NULL OR q.order_type = p_order_type::integer)
      AND (p_service_advisor IS NULL OR q.service_advisor = p_service_advisor)
      AND (
        v_is_internal
        OR (
          v_user_role = 170 AND EXISTS (
            SELECT 1
            FROM qvm_new_apps.client_branches cb
            JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = q.quotation_id
            WHERE cb.customer_id = v_user_branch
              AND cb.customer_id = qi.customer_id
            LIMIT 1
          )
        )
        OR (
          v_user_role != 170 AND EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi2
            WHERE qi2.quotation_id = q.quotation_id
              AND qi2.customer_id = v_user_branch
            LIMIT 1
          )
        )
      )
      AND (
        NOT v_is_internal
        OR p_branch_id IS NULL
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi_branch
          WHERE qi_branch.quotation_id = q.quotation_id
            AND qi_branch.customer_id = p_branch_id
        )
      )
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qis
          WHERE qis.quotation_id = q.quotation_id
            AND (
              qis.part_number ILIKE '%' || p_search || '%'
              OR qis.part_description ILIKE '%' || p_search || '%'
              OR qis.vin ILIKE '%' || p_search || '%'
            )
        )
      )
      AND (
        p_status IS NULL
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi_status
          WHERE qi_status.quotation_id = q.quotation_id
            AND qi_status.item_status = p_status::integer
        )
      )
  ),
  total_cte AS (
    SELECT COUNT(*)::int AS total_count FROM candidates
  ),
  paged AS (
    SELECT quotation_id, created_at
    FROM candidates
    ORDER BY created_at DESC
    LIMIT GREATEST(1, COALESCE(p_limit,10))
    OFFSET GREATEST(0, COALESCE(p_offset,0))
  ),
  quotation_notes AS (
    SELECT n.type_id AS quotation_id, COUNT(*)::int AS notes_count
    FROM qvm_new_apps.notes n
    WHERE n.note_type = 'quotations' AND n.is_internal = FALSE
      AND n.type_id IN (SELECT quotation_id FROM paged)
    GROUP BY n.type_id
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'RFQs fetched successfully',
    'data', COALESCE(jsonb_agg(r.rq ORDER BY r.created_at DESC), '[]'::jsonb),
    'total_count', (SELECT total_count FROM total_cte)
  )
  INTO v_result
  FROM (
    SELECT q.created_at,
      jsonb_build_object(
        'quotation_id', q.quotation_id,
        'order_number', q.order_number,
        'plate_number', q.plate_number,
        'created_at', q.created_at,
        'service_advisor', u.user_name,
        'service_advisor_id', q.service_advisor,
        'delivery_type', ld_delivery.list_data,
        'order_type', ld_order.list_data,
        'shipping_price', q.shipping_price,
        'shipping_type', q.shipping_type,
        'discount_amount', NULL,
        'branch_id', b.customer_id,
        'branch_name', b.branch_name,
        'client_company_id', b.list_data_id,
        'client_company', ld_company.list_data,
        'insurance_company_id', q.insurance_company_id,
        'insurance_company_name', ic.name,
        'rfq_status', status_info.status,
        'vin', vehicle_info.vin,
        'main_brand', vehicle_info.main_brand,
        'model', vehicle_info.model,
        'year', vehicle_info.year,
        'items', items_info.items,
        'notes_count', COALESCE(qn.notes_count, 0)
      ) AS rq
    FROM paged p
    JOIN qvm_new_apps.quotations q ON q.quotation_id = p.quotation_id
    LEFT JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
    LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = q.delivery_type
    LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = q.order_type
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = q.insurance_company_id
    LEFT JOIN quotation_notes qn ON qn.quotation_id = q.quotation_id

    LEFT JOIN LATERAL (
      SELECT qi.customer_id AS customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
      ORDER BY qi.quotation_item_id ASC
      LIMIT 1
    ) first_branch ON true

    LEFT JOIN qvm_new_apps.client_branches b ON b.customer_id = first_branch.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_company ON ld_company.list_data_id = b.list_data_id

    LEFT JOIN LATERAL (
      SELECT
        qi3.vin AS vin,
        ld_brand.list_data AS main_brand,
        qi3.model AS model,
        qi3.year AS year
      FROM qvm_new_apps.quotation_items qi3
      LEFT JOIN qvm_new_apps.list_data ld_brand ON ld_brand.list_data_id = qi3.main_brand
      WHERE qi3.quotation_id = q.quotation_id
      ORDER BY qi3.quotation_item_id ASC
      LIMIT 1
    ) vehicle_info ON true

    LEFT JOIN LATERAL (
      SELECT
        qi2.item_status as item_status_id,
        ldr.list_data AS status,
        CASE
          WHEN p_status IS NULL THEN true
          ELSE EXISTS (
            SELECT 1
            FROM qvm_new_apps.quotation_items qi_check
            WHERE qi_check.quotation_id = q.quotation_id
              AND qi_check.item_status = p_status::integer
          )
        END as has_filtered_status
      FROM qvm_new_apps.quotation_items qi2
      LEFT JOIN qvm_new_apps.list_data ldr ON ldr.list_data_id = qi2.item_status
      WHERE qi2.quotation_id = q.quotation_id
      ORDER BY qi2.quotation_item_id ASC
      LIMIT 1
    ) status_info ON true

    LEFT JOIN LATERAL (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'quotation_item_id', qi.quotation_item_id,
            'part_number', qi.part_number,
            'part_description', qi.part_description,
            'quantity', qi.quantity,
            'brand_class', ld_bc.list_data,
            'alternative_part_number', qi.alternative_part_number,
            'alternative_brand_class', ld_abc.list_data,
            'part_photo', qi.part_photo,
            'delivery_type', ld_delivery2.list_data,
            'order_type', ld_order2.list_data,
            'estimated_price', qi.estimated_price,
            'price_before_vat', qi.price_before_vat,
            'discount_percent', qi.discount_percent,
            'agency_price', qi.agency_price,
            'total_price_before_vat', qi.total_price_before_vat,
            'final_part_number', ci.final_part_number,
            'approved_qty', ci.approved_qty,
            'sla', qvi.sla,
            'item_status', ldr2.list_data,
            'item_status_id', qi.item_status,
            'vin', qi.vin,
            'main_brand', ld_brand2.list_data,
            'model', qi.model,
            'year', qi.year,
            'branch_id', qi.customer_id,
            'item_notes_count', (
              SELECT COUNT(*)::int
              FROM qvm_new_apps.notes n
              WHERE n.note_type = 'quotation_items'
                AND n.type_id = qi.quotation_item_id
                AND n.is_internal = FALSE
            )
          )
          ORDER BY qi.quotation_item_id
        ),
        '[]'::jsonb
      ) AS items
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
      LEFT JOIN qvm_new_apps.list_data ldr2 ON ldr2.list_data_id = qi.item_status
      LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
      LEFT JOIN qvm_new_apps.list_data ld_abc ON ld_abc.list_data_id = qi.alternative_brand_class
      LEFT JOIN qvm_new_apps.list_data ld_brand2 ON ld_brand2.list_data_id = qi.main_brand
      -- Use quotations-level delivery_type/order_type for labels
      LEFT JOIN qvm_new_apps.list_data ld_delivery2 ON ld_delivery2.list_data_id = q.delivery_type
      LEFT JOIN qvm_new_apps.list_data ld_order2 ON ld_order2.list_data_id = q.order_type
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
      WHERE qi.quotation_id = q.quotation_id
        AND (
          v_is_internal
          OR (
            v_user_role = 170
            AND EXISTS (
              SELECT 1
              FROM qvm_new_apps.client_branches cb2
              WHERE cb2.customer_id = v_user_branch
                AND cb2.customer_id = qi.customer_id
            )
          )
          OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
        )
    ) items_info ON true

    WHERE TRUE
  ) r;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.client_main_dashboard(p_user_id uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
  v_company INT;
  v_user_branch INT;
  v_user_role INT;
  v_result JSON;
BEGIN
  -- 1) Get user context
  SELECT 
    user_company, 
    user_branch, 
    user_role
  INTO 
    v_company, 
    v_user_branch, 
    v_user_role
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id;

  -- 2) Build JSON response
  SELECT json_build_object(
    'status', 'success',
    'message', 'Quotations fetched successfully',
    'data', COALESCE(
      json_agg(
        json_build_object(
          -- Quotation Header
          'quotation_id', q.quotation_id,
          'order_number', q.order_number,
          'plate_number', q.plate_number,
          'created_at', q.created_at,
          'service_advisor', u.user_name,
          'delivery_type', ld1.list_data,
          'order_type', ld5.list_data,
          'shipping_price', q.shipping_price,

          -- Quotation Notes
          'quotation_notes', (
            SELECT COALESCE(
              json_agg(
                json_build_object(
                  'note_description', n.note_description,
                  'note_attachment', n.note_attachment,
                  'created_at', n.created_at,
                  'user_name', uu.user_name
                )
                ORDER BY n.created_at DESC
              ),
              '[]'::json
            )
            FROM qvm_new_apps.notes n
            LEFT JOIN qvm_new_apps.user_data uu 
              ON uu.user_id = n.user_id
            WHERE n.note_type = 'quotation note'
              AND n.type_id = q.quotation_id
              AND n.is_internal = FALSE
          ),

          -- Items
          'items', (
            SELECT COALESCE(
              json_agg(
                json_build_object(
                  'quotation_item_id', qi.quotation_item_id,
                  'branch', qi.customer_id,  -- ✅ correct: branch stored here
                  'vin', qi.vin,
                  'main_brand', ld3.list_data,
                  'model', qi.model,
                  'part_description', qi.part_description,
                  'part_number', qi.part_number,
                  'quantity', qi.quantity,
                  'brand_class', ld4.list_data,
                  'part_photo', qi.part_photo,
                  'price_before_vat', qi.price_before_vat,
                  'total_price_before_vat', qi.total_price_before_vat,
                  'final_part_number', ci.final_part_number,
                  'approved_qty', ci.approved_qty,
                  'client_return_reason', ci.client_return_reason,
                  'agency_price', qi.agency_price,
                  'discount_percent', qi.discount_percent,
                  'item_status', COALESCE(ld2_confirmed.list_data, ld2_rfq.list_data),
                  'cancellation_reason', qi.cancellation_reason,

                  -- Item Notes
                  'item_notes', (
                    SELECT COALESCE(
                      json_agg(
                        json_build_object(
                          'note_description', n.note_description,
                          'note_attachment', n.note_attachment,
                          'created_at', n.created_at,
                          'user_name', uu.user_name
                        )
                        ORDER BY n.created_at DESC
                      ),
                      '[]'::json
                    )
                    FROM qvm_new_apps.notes n
                    LEFT JOIN qvm_new_apps.user_data uu 
                      ON uu.user_id = n.user_id
                    WHERE n.note_type = 'quotation_item note'
                      AND n.type_id = qi.quotation_item_id
                      AND n.is_internal = FALSE
                  )
                )
              ),
              '[]'::json
            )
            FROM qvm_new_apps.quotation_items qi
            LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
            LEFT JOIN qvm_new_apps.list_data ld2_rfq ON ld2_rfq.list_data_id = qi.item_status
            LEFT JOIN qvm_new_apps.list_data ld2_confirmed ON ld2_confirmed.list_data_id = ci.item_status
            LEFT JOIN qvm_new_apps.list_data ld3 ON ld3.list_data_id = qi.main_brand
            LEFT JOIN qvm_new_apps.list_data ld4 ON ld4.list_data_id = qi.brand_class
            WHERE qi.quotation_id = q.quotation_id
              -- ✅ apply branch filter at item level
              AND (
                v_company = 185
                OR (
                  v_user_role = 170
                  AND EXISTS (
                    SELECT 1
                    FROM qvm_new_apps.client_branches cb2
                    WHERE cb2.customer_id = v_user_branch
                      AND cb2.customer_id = qi.customer_id
                  )
                )
                OR (v_user_role != 170 AND qi.customer_id = v_user_branch)
              )
          )
        )
        ORDER BY q.quotation_id DESC, q.created_at DESC
      ),
      '[]'::json
    )
  )
  INTO v_result
  FROM qvm_new_apps.quotations q
  JOIN qvm_new_apps.user_data u ON u.user_id = q.service_advisor
  LEFT JOIN qvm_new_apps.list_data ld1 ON ld1.list_data_id = q.delivery_type
  LEFT JOIN qvm_new_apps.list_data ld5 ON ld5.list_data_id = q.order_type
  WHERE q.created_at >= NOW() - INTERVAL '2 months';

  RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_branch_ids int[] := COALESCE(p_branch_ids, ARRAY[]::int[]);
  v_supplier_ids int[] := COALESCE(p_supplier_ids, ARRAY[]::int[]);
  v_result jsonb;
BEGIN
  WITH
  user_ctx AS (
    SELECT ud.user_company AS company, ud.user_branch AS user_branch, ud.user_role AS user_role, (ud.user_type = 185) AS is_internal
    FROM qvm_new_apps.user_data ud WHERE ud.user_id = p_user_id
  ),
  order_scope AS (
    SELECT co.confirmed_order_id
    FROM qvm_new_apps.confirmed_orders co
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    JOIN user_ctx uc ON true
    WHERE uc.is_internal
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = uc.user_branch AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  po_agg AS (
    SELECT pi.purchase_order_id,
      count(*)                                                                        AS item_count,
      count(*) FILTER (WHERE pi.receipt_status = 'received')                          AS received_count,
      count(*) FILTER (WHERE pi.receipt_status = 'lower_qty')                         AS lower_qty_count,
      count(*) FILTER (WHERE pi.receipt_status = 'wrong_part')                        AS wrong_part_count,
      count(*) FILTER (WHERE pi.receipt_status IS NULL OR pi.receipt_status = 'not_received') AS not_received_count,
      count(*) FILTER (WHERE COALESCE(pi.returned_qty, 0) > 0)                        AS returned_count,
      sum(GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0))   AS total_approved_qty,
      sum(COALESCE(pi.returned_qty, 0))                                               AS total_returned_qty,
      sum(COALESCE(qvi.cost, 0) * GREATEST(COALESCE(pi.approved_qty, 0) - COALESCE(pi.returned_qty, 0), 0)) AS total_value
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
    WHERE pi.purchase_order_id IS NOT NULL
    GROUP BY pi.purchase_order_id
  ),
  vcn_by_po AS (
    SELECT vcn.purchase_order_id, count(*) AS vcn_count
    FROM qvm_new_apps.vendor_creditnotes vcn GROUP BY vcn.purchase_order_id
  ),
  base AS (
    SELECT
      po.purchase_order_id,
      ('PO-' || po.purchase_order_id) AS po_number,
      q.order_number,
      co.created_at AS confirmation_date,
      po.created_at AS po_created_at,
      vnd.vendor_name,
      po.vendor_id,
      cb.branch_name,
      first_branch.customer_id,
      -- Falls back to uploaded_by: POs raised through upsert_purchase_order_items record the user
      -- there, and older rows predate the created_by trigger.
      COALESCE(ucb.user_name, uup.user_name) AS created_by_name,
      COALESCE(po.created_by, po.uploaded_by) AS created_by,
      a.item_count, a.received_count, a.lower_qty_count, a.wrong_part_count, a.not_received_count,
      a.returned_count, a.total_approved_qty, a.total_returned_qty, a.total_value,
      po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url,
      COALESCE(v.vcn_count, 0) AS vcn_count
    FROM qvm_new_apps.purchase_orders po
    JOIN po_agg a ON a.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
    LEFT JOIN qvm_new_apps.user_data ucb ON ucb.user_id = po.created_by
    LEFT JOIN qvm_new_apps.user_data uup ON uup.user_id = po.uploaded_by
    LEFT JOIN vcn_by_po v ON v.purchase_order_id = po.purchase_order_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_branch.customer_id
  ),
  filtered AS (
    SELECT * FROM base b
    WHERE (p_search IS NULL OR p_search = '' OR b.order_number ILIKE '%'||p_search||'%' OR b.vendor_name ILIKE '%'||p_search||'%' OR b.po_number ILIKE '%'||p_search||'%'
           OR b.created_by_name ILIKE '%'||p_search||'%')
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR b.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR b.vendor_id = ANY(v_supplier_ids))
      AND (NOT p_missing_pi OR (
        (coalesce(nullif(trim(b.vendor_invoice_url), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.vendor_invoice_number), ''), null) IS NULL)
        AND (coalesce(nullif(trim(b.zoho_bill_url), ''), null) IS NULL)
      ))
      AND (NOT p_missing_rn OR b.vcn_count = 0)
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'total', (SELECT count(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.purchase_order_id DESC) FROM (
        SELECT purchase_order_id, po_number, order_number, confirmation_date, po_created_at,
               vendor_name, branch_name, created_by, created_by_name,
               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               returned_count, total_approved_qty, total_returned_qty, total_value
        FROM filtered ORDER BY purchase_order_id DESC LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;


-- Orders Dashboard: hold a client user to their own branch --------------------------------------
-- get_orders_with_item_status had no access control whatsoever — it took p_user_id, assigned it to
-- a variable and never read it again, so any signed-in user got every order from every company.
-- That is a leak, and it also made the branch narrowing above pointless on that page.

CREATE OR REPLACE FUNCTION public.get_orders_with_item_status(p_status_id integer, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_result jsonb;
  v_user_id uuid;
  v_user_type int;
  v_user_branch int;
  v_is_internal boolean;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  -- This function had no access control at all: it accepted p_user_id, assigned it here and never
  -- looked at it again, so every caller saw every order from every company. A client user is now
  -- held to their own branch. Reading the branch straight off quotation_items is safe because a
  -- quotation never spans two customers.
  SELECT ud.user_type, ud.user_branch
    INTO v_user_type, v_user_branch
  FROM qvm_new_apps.user_data ud
  WHERE ud.user_id = v_user_id;

  v_is_internal := (v_user_type = 185);

  SELECT jsonb_build_object(
    'status', 'success',
    'total_count', (SELECT COUNT(DISTINCT q.quotation_id)
                  FROM qvm_new_apps.quotation_items qi
                  JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
                  WHERE qi.item_status = p_status_id
                    AND (v_is_internal OR qi.customer_id = v_user_branch)),
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
        AND (v_is_internal OR qi.customer_id = v_user_branch)
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
$function$;
