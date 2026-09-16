-- The order names its customer, and the customer can answer.
--
-- Three things the previous migration left hanging. quotations.end_customer_id existed but nothing
-- wrote it; the approval rounds could be read with a mailed token but not by a signed-in workshop
-- or customer user; and the client's price was snapshotted from the vendor's before-discount figure
-- when what the pricing user actually sets — and what the customer is really being asked to accept
-- — is the selling price on the line.
--
-- The customer of an order is an end_customers row, chosen when the RFQ is raised from the list the
-- workshop keeps. The insurance-company field the form used to carry is superseded: an insurer is
-- one kind of end customer now, and naming it twice would let the two disagree.

-- ── 1. Raising an order names its customer ────────────────────────────────────────────────────
--
-- A new defaulted parameter is a new overload, and two overloads that differ only in a trailing
-- default are exactly what PostgREST refuses to choose between (PGRST203). The old signature goes.
DROP FUNCTION IF EXISTS qvm_new_apps.create_quotation_with_items(
  uuid, integer, integer, text, uuid, integer, integer, bigint, jsonb, bigint, text, text, text, bigint);

CREATE OR REPLACE FUNCTION qvm_new_apps.create_quotation_with_items(p_account_manager uuid, p_delivery_type integer, p_order_type integer, p_plate_number text, p_service_advisor uuid, p_client_id integer, p_region_id integer, p_customer_id bigint, p_items jsonb, p_insurance_company_id bigint, p_order_number text, p_notes text, p_request_kind text DEFAULT 'purchase'::text, p_customer_address_id bigint DEFAULT NULL::bigint, p_end_customer_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation qvm_new_apps.quotations;
  v_order_number text;
  v_item jsonb;
  v_items_payload jsonb := '[]'::jsonb;
  v_est numeric;
  v_inserted_items jsonb;
  v_kind text;
  v_addr bigint;
BEGIN
  IF NOT jsonb_typeof(p_items) = 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Items are required';
  END IF;

  v_kind := lower(nullif(btrim(coalesce(p_request_kind, '')), ''));
  IF v_kind IS NULL THEN v_kind := 'purchase'; END IF;
  IF v_kind NOT IN ('quote', 'purchase') THEN
    RAISE EXCEPTION 'نوع الطلب غير معروف: %', p_request_kind;
  END IF;

  -- «عرض سعر» is only on offer to a customer whose approvals are switched on:
  -- the priced offer has to route through someone, and with approvals off
  -- there is nobody to route it to.
  IF v_kind = 'quote' AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.customers c
        WHERE c.list_data_id = p_client_id AND c.approvals_enabled AND c.merged_into IS NULL) THEN
    RAISE EXCEPTION 'هذا العميل لا تُفعَّل عنده الاعتمادات، فلا يمكن إنشاء «عرض سعر»';
  END IF;

  -- An address switched off, not meant to receive orders, or belonging somewhere else is not an
  -- address this order can be sent to.
  --
  -- Ownership is checked against the BRANCH the order is being raised on. It used to be checked
  -- against the company, through customer_addresses.customer_id -> customers.list_data_id, which
  -- was right while a branch belonged to exactly one company. It is not right now: a branch owns
  -- its addresses, a workshop serves several companies, and an address created from the client
  -- tree has customer_id NULL whenever the branch's company has no customers row — so the company
  -- join would refuse an address the order form had just offered. The company form is kept for the
  -- addresses that genuinely are a company's.
  IF p_customer_address_id IS NOT NULL THEN
    SELECT a.address_id INTO v_addr
      FROM qvm_new_apps.customer_addresses a
     WHERE a.address_id = p_customer_address_id
       AND a.is_active
       AND a.receives_orders
       AND (
             a.client_branch_id = p_customer_id
             OR (a.client_branch_id IS NULL AND EXISTS (
                   SELECT 1 FROM qvm_new_apps.customers c
                    WHERE c.customer_id = a.customer_id AND c.list_data_id = p_client_id))
           );
    IF v_addr IS NULL THEN
      RAISE EXCEPTION 'العنوان المختار لا يخص هذا الفرع أو لا يستقبل طلبات';
    END IF;
  END IF;

  v_order_number := NULLIF(btrim(p_order_number), '');
  IF v_order_number IS NULL THEN
    v_order_number := qvm_new_apps.generate_rfq_order_number(p_client_id, p_region_id);
  END IF;

  INSERT INTO qvm_new_apps.quotations (
    order_number, plate_number, order_type, delivery_type, service_advisor, account_manager,
    shipping_type, insurance_company_id, request_kind, customer_address_id, end_customer_id,
    -- The company the order is for. It used to be inferable from the branch; a branch now serves
    -- several companies, so the choice made when raising the order is the only record of it.
    company_id
  ) VALUES (
    v_order_number, p_plate_number, p_order_type, p_delivery_type, p_service_advisor,
    p_account_manager, 'item', p_insurance_company_id, v_kind, v_addr, p_end_customer_id,
    p_client_id
  ) RETURNING * INTO v_quotation;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_est := public.get_estimated_price(
      p_client_id := p_client_id,
      p_part_number := v_item->>'part_number',
      p_brand_class_id := (v_item->>'brand_class')::integer
    );
    v_items_payload := v_items_payload || jsonb_build_object(
      'quotation_id', v_quotation.quotation_id,
      'customer_id', p_customer_id,
      'vin', v_item->'vin',
      'main_brand', v_item->'main_brand',
      'model', v_item->'model',
      'part_number', v_item->'part_number',
      'part_description', v_item->'part_description',
      'quantity', v_item->'quantity',
      'brand_class', v_item->'brand_class',
      'part_photo', v_item->'part_photo',
      'item_status', CASE WHEN COALESCE(v_item->>'part_number', '') <> '' THEN 235 ELSE 236 END,
      'item_PK', v_item->'item_PK',
      'estimated_price', v_est
    );
  END LOOP;

  SELECT jsonb_agg(to_jsonb(t)) INTO v_inserted_items
  FROM public.create_quotation_items(v_items_payload) t;

  -- Inserted directly rather than via public.create_quotation_note: that function now requires
  -- auth.uid() (20260812100000_notes_rpc_authorization.sql, closing a real hole where it used to
  -- trust a caller-supplied p_user_id with no check at all). But this whole function is called by
  -- the create_quotation_with_items EDGE FUNCTION using the service-role client, not the end
  -- user's own session — auth.uid() is NULL in that context even though the edge function already
  -- independently verified the real user via auth.getUser(jwt) and passed that identity along as
  -- p_service_advisor. This is already a trusted, pre-authenticated context (reachable only
  -- through that edge function), so it's safe to write the note directly with p_service_advisor
  -- rather than route through the externally-facing, auth.uid()-checked wrapper.
  IF p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN
    INSERT INTO qvm_new_apps.notes (type_id, note_type, note_description, user_id, created_at)
    VALUES (v_quotation.quotation_id, 'quotations', p_notes, p_service_advisor, now());
  END IF;

  RETURN jsonb_build_object(
    'quotation_id', v_quotation.quotation_id,
    'order_number', v_quotation.order_number,
    'request_kind', v_quotation.request_kind,
    'customer_address_id', v_quotation.customer_address_id,
    'end_customer_id', v_quotation.end_customer_id,
    'items', COALESCE(v_inserted_items, '[]'::jsonb)
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_quotation_with_items(
  uuid, integer, integer, text, uuid, integer, integer, bigint, jsonb, bigint, text, text, text, bigint, bigint)
  TO service_role;

-- The customers a workshop keeps, for the RFQ form. Given a workshop directly, or a branch — a
-- branch knows its workshop, and the form does not always have the workshop in hand.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_end_customers_for_order(
  p_workshop_id bigint DEFAULT NULL, p_branch_id integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  WITH ws AS (
    SELECT COALESCE(p_workshop_id,
                    (SELECT cb.workshop_id FROM qvm_new_apps.client_branches cb
                      WHERE cb.customer_id = p_branch_id)) AS workshop_id
  )
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'end_customer_id', v.end_customer_id,
             'name',            v.name,
             'customer_kind',   v.customer_kind,
             'customer_code',   v.customer_code,
             'user_count',      v.user_count) ORDER BY v.name)
      FROM qvm_new_apps.end_customer_owners o
      JOIN qvm_new_apps.v_end_customers v ON v.end_customer_id = o.end_customer_id
      JOIN ws ON ws.workshop_id = o.workshop_id
     WHERE v.is_active), '[]'::jsonb);
$function$;

-- ── 2. The dashboards say who the customer is ─────────────────────────────────────────────────
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
        'end_customer_id', q.end_customer_id,
        'end_customer_name', vec.name,
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
    LEFT JOIN qvm_new_apps.v_end_customers vec ON vec.end_customer_id = q.end_customer_id
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
CREATE OR REPLACE FUNCTION public.get_internal_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_account_managers uuid[] DEFAULT NULL::uuid[], p_clients integer[] DEFAULT NULL::integer[], p_branches integer[] DEFAULT NULL::integer[], p_brands integer[] DEFAULT NULL::integer[], p_statuses integer[] DEFAULT NULL::integer[], p_insurance_company_ids bigint[] DEFAULT NULL::bigint[], p_mode text DEFAULT 'regular'::text, p_view text DEFAULT 'rfqs'::text, p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0, p_quotation_ids integer[] DEFAULT NULL::integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_branch_scope integer[];
  v_result jsonb;
  v_rfq_statuses  int[] := ARRAY[17, 216, 217, 218, 235, 236, 237];
  -- Settled(31) belongs with the order statuses: it is what a Delivered line becomes once the
  -- vendor invoice lands, and leaving it out made finished orders vanish from the Orders view.
  v_order_statuses int[] := ARRAY[19, 21, 22, 23, 31];
BEGIN
  SELECT user_type INTO v_user_type
  FROM qvm_new_apps.user_data WHERE user_id = p_user_id;

  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Access denied: Internal users only',
      'data', '[]'::jsonb
    );
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(p_user_id);

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
      q.insurance_company_id,
      q.end_customer_id,
      q.customer_address_id,
      co.confirmed_order_id,
      co.created_at AS confirmation_date,
      (
        SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC LIMIT 1
      ) AS customer_id,
      (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
      ) AS order_search_matched
    FROM qvm_new_apps.quotations q
    LEFT JOIN qvm_new_apps.confirmed_orders co ON co.quotation_id = q.quotation_id
    WHERE
      EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi_any WHERE qi_any.quotation_id = q.quotation_id)
      AND (p_quotation_ids IS NULL OR q.quotation_id = ANY(p_quotation_ids))
      AND (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_account_managers IS NULL OR q.account_manager = ANY(p_account_managers))
      AND (
        p_search IS NULL
        OR q.order_number ILIKE '%' || p_search || '%'
        OR q.plate_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM qvm_new_apps.quotation_items qi2
          LEFT JOIN qvm_new_apps.confirmed_items ci2 ON ci2.quotation_item_id = qi2.quotation_item_id
          WHERE qi2.quotation_id = q.quotation_id
            AND (
              qi2.part_number ILIKE '%' || p_search || '%'
              OR qi2.part_description ILIKE '%' || p_search || '%'
              OR qi2.vin ILIKE '%' || p_search || '%'
              OR ci2.final_part_number ILIKE '%' || p_search || '%'
            )
        )
      )
      AND (
        p_view = 'all'
        OR (p_view = 'rfqs' AND (
          co.confirmed_order_id IS NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_rfq_statuses)
          )
        ))
        OR (p_view = 'orders' AND (
          co.confirmed_order_id IS NOT NULL
          OR EXISTS (
            SELECT 1 FROM qvm_new_apps.quotation_items qi3
            WHERE qi3.quotation_id = q.quotation_id
              AND qi3.item_status = ANY(v_order_statuses)
          )
        ))
      )
  ),
  filtered_with_branch AS (
    SELECT
      fq.*,
      cb.customer_id AS branch_id,
      cb.branch_name,
      cb.list_data_id AS client_id,
      cb.is_bulk_client,
      ld_client.list_data AS client_name,
      ic.name AS insurance_company_name,
      vec.name AS end_customer_name
    FROM filtered_quotations fq
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fq.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = fq.insurance_company_id
    LEFT JOIN qvm_new_apps.v_end_customers vec ON vec.end_customer_id = fq.end_customer_id
    WHERE
      (p_branches IS NULL OR cb.customer_id = ANY(p_branches))
      AND (p_clients IS NULL OR cb.list_data_id = ANY(p_clients))
      AND (p_insurance_company_ids IS NULL OR fq.insurance_company_id = ANY(p_insurance_company_ids))
      AND (v_branch_scope IS NULL OR cb.customer_id = ANY(v_branch_scope))
      AND (
        (p_mode = 'bulk' AND cb.is_bulk_client = true)
        OR (p_mode = 'regular' AND (cb.is_bulk_client = false OR cb.is_bulk_client IS NULL))
        OR p_mode IS NULL
      )
  ),
  paged_filtered AS (
    SELECT * FROM filtered_with_branch
    ORDER BY rfq_date DESC
    LIMIT GREATEST(p_limit, 1)
    OFFSET GREATEST(p_offset, 0)
  )
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Internal dashboard data fetched successfully',
    'total_count', (SELECT COUNT(*) FROM filtered_with_branch),
    'data', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
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
            'insurance_company_id', fwb.insurance_company_id,
            'insurance_company_name', fwb.insurance_company_name,
            'end_customer_id', fwb.end_customer_id,
            'end_customer_name', fwb.end_customer_name,
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
              SELECT jsonb_agg(
                jsonb_build_object(
                  'account_manager_id', qam.assigned_to,
                  'account_manager_name', am_hist.user_name,
                  'assigned_at', qam.created_at
                )
                ORDER BY qam.created_at DESC
              )
              FROM qvm_new_apps.quotation_account_managers qam
              LEFT JOIN qvm_new_apps.user_data am_hist ON am_hist.user_id = qam.assigned_to
              WHERE qam.quotation_id = fwb.quotation_id
            ),
            'items', (
              SELECT jsonb_agg(
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
                      )
                      ORDER BY n.created_at DESC
                    )
                    FROM qvm_new_apps.notes n
                    LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
                    WHERE n.note_type = 'quotation_items'
                      AND n.type_id = qi.quotation_item_id
                      AND n.is_internal = false
                      AND n.deleted_at IS NULL
                  )
                )
                ORDER BY qi.quotation_item_id ASC
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
                AND (
                  p_view = 'all'
                  OR (p_view = 'rfqs'    AND qi.item_status = ANY(v_rfq_statuses))
                  OR (p_view = 'orders'  AND qi.item_status = ANY(v_order_statuses))
                )
                AND (
                  fwb.order_search_matched
                  OR p_search IS NULL
                  OR qi.part_number ILIKE '%' || p_search || '%'
                  OR qi.part_description ILIKE '%' || p_search || '%'
                  OR qi.vin ILIKE '%' || p_search || '%'
                  OR ci.final_part_number ILIKE '%' || p_search || '%'
                )
            ),
            'quotation_notes', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'note_id', n.note_id,
                  'note_text', n.note_description,
                  'created_by', n_creator.user_name,
                  'created_at', n.created_at
                )
                ORDER BY n.created_at DESC
              )
              FROM qvm_new_apps.notes n
              LEFT JOIN qvm_new_apps.user_data n_creator ON n_creator.user_id = n.user_id
              WHERE n.note_type = 'quotations'
                AND n.type_id = fwb.quotation_id
                AND n.is_internal = false
                AND n.deleted_at IS NULL
            ),
            'payment_account', (
              SELECT ld_payment.list_data
              FROM qvm_new_apps.purchase_orders po
              LEFT JOIN qvm_new_apps.list_data ld_payment ON ld_payment.list_data_id = po.payment_account
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            ),
            -- Where the parts are going. The order's own address when it named one; otherwise the
            -- branch's default, marked as such — every order raised before the delivery-address
            -- field existed named nothing, and showing a blank column for all of them would say
            -- less than saying where that branch normally receives.
            'delivery_address', (
              SELECT jsonb_build_object(
                       'address_id', a.address_id,
                       'label', a.label,
                       'address_line', a.address_line,
                       'city', COALESCE(vc.name, a.city),
                       'district', vd.name,
                       'postal_code', a.postal_code,
                       'contact_name', a.contact_name,
                       'contact_phone', a.contact_phone,
                       'is_branch_default', fwb.customer_address_id IS NULL)
                FROM qvm_new_apps.customer_addresses a
                LEFT JOIN qvm_new_apps.v_cities vc    ON vc.city_id = a.city_id
                LEFT JOIN qvm_new_apps.v_districts vd ON vd.district_id = a.district_id
               WHERE a.address_id = COALESCE(
                       fwb.customer_address_id,
                       (SELECT d.address_id FROM qvm_new_apps.customer_addresses d
                         WHERE d.client_branch_id = fwb.branch_id
                           AND d.is_active AND d.is_default
                         LIMIT 1))
               LIMIT 1),
            'payment_account_id', (
              SELECT po.payment_account
              FROM qvm_new_apps.purchase_orders po
              WHERE po.confirmed_order_id = fwb.confirmed_order_id
              LIMIT 1
            )
          )
          ORDER BY fwb.rfq_date DESC
        )
        FROM paged_filtered fwb
        LEFT JOIN qvm_new_apps.user_data sa ON sa.user_id = fwb.service_advisor
        LEFT JOIN qvm_new_apps.user_data am ON am.user_id = fwb.account_manager
        LEFT JOIN qvm_new_apps.list_data ld_delivery ON ld_delivery.list_data_id = fwb.delivery_type
        LEFT JOIN qvm_new_apps.list_data ld_order ON ld_order.list_data_id = fwb.order_type
      ),
      '[]'::jsonb
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$function$;
-- ── 3. The client approves the selling price, not the vendor's list price ─────────────────────
--
-- send_quotation_for_approval snapshotted customer_price from agency_price. The pricing user sets
-- a selling price on the line (price_before_vat) — filled from agency_price by default, but theirs
-- to change — and that is the figure the customer is asked to accept. Falls back to agency_price
-- only where no selling price was ever set.
CREATE OR REPLACE FUNCTION qvm_new_apps.send_quotation_for_approval(
  p_quotation_id bigint, p_audiences text[], p_item_ids bigint[] DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_audience text;
  v_round    bigint;
  v_customer bigint;
  v_out      jsonb := '[]'::jsonb;
  v_count    integer;
BEGIN
  IF NOT qvm_new_apps.is_qparts_team() THEN
    RAISE EXCEPTION 'Only the Qparts team can send an order for approval';
  END IF;

  SELECT q.end_customer_id INTO v_customer
    FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id;

  FOREACH v_audience IN ARRAY COALESCE(p_audiences, ARRAY[]::text[]) LOOP
    IF v_audience NOT IN ('workshop', 'client') THEN
      RAISE EXCEPTION 'Unknown approval audience: %', v_audience;
    END IF;

    -- Re-sending while a round is open reuses it rather than raising a second one; the unique index
    -- would refuse the insert anyway, and silently failing would be worse than reusing.
    SELECT r.approval_round_id INTO v_round
      FROM qvm_new_apps.quotation_approval_rounds r
     WHERE r.quotation_id = p_quotation_id AND r.audience = v_audience AND r.status = 'pending';

    IF v_round IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_approval_rounds
        (quotation_id, audience, end_customer_id, sent_by)
      VALUES (p_quotation_id, v_audience,
              CASE WHEN v_audience = 'client' THEN v_customer END, auth.uid())
      RETURNING approval_round_id INTO v_round;
    END IF;

    -- The lines, priced from the vendor offer currently marked best — or the only one there is.
    -- Both prices are snapshotted on every round regardless of audience: the round records what was
    -- true, and the read function decides what the reader is shown.
    INSERT INTO qvm_new_apps.quotation_approval_items
      (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity)
    SELECT v_round, qi.quotation_item_id, best.cost_id, best.cost,
           COALESCE(NULLIF(qi.price_before_vat, 0), best.agency_price), qi.quantity
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN LATERAL (
        SELECT qvi.cost_id, qvi.cost, qvi.agency_price
          FROM qvm_new_apps.quotation_vendor_items qvi
         WHERE qvi.quotation_item_id = qi.quotation_item_id
           AND qvi.cost IS NOT NULL AND qvi.cost > 0
         ORDER BY qvi.best_cost DESC, qvi.cost ASC
         LIMIT 1
      ) best ON true
     WHERE qi.quotation_id = p_quotation_id
       AND (p_item_ids IS NULL OR qi.quotation_item_id = ANY(p_item_ids))
       -- A part still waiting on somebody's decision is not part of the order yet, so it is not
       -- part of what is being approved either.
       AND qi.item_status NOT IN (
         SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
          WHERE ld.list_id = 3
            AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
    ON CONFLICT (approval_round_id, quotation_item_id) DO UPDATE
      SET cost_id         = EXCLUDED.cost_id,
          wholesale_price = EXCLUDED.wholesale_price,
          customer_price  = EXCLUDED.customer_price,
          quantity        = EXCLUDED.quantity;

    UPDATE qvm_new_apps.quotation_approval_rounds r
       SET total_amount = (
             SELECT COALESCE(SUM(COALESCE(CASE WHEN v_audience = 'workshop'
                                               THEN ai.wholesale_price ELSE ai.customer_price END, 0)
                                 * COALESCE(ai.quantity, 1)), 0)
               FROM qvm_new_apps.quotation_approval_items ai
              WHERE ai.approval_round_id = v_round AND ai.decision <> 'cancelled')
     WHERE r.approval_round_id = v_round;

    SELECT count(*) INTO v_count
      FROM qvm_new_apps.quotation_approval_items WHERE approval_round_id = v_round;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'approval_round_id', v_round,
      'audience', v_audience,
      'items', v_count,
      'access_token', (SELECT r.access_token FROM qvm_new_apps.quotation_approval_rounds r
                        WHERE r.approval_round_id = v_round)));
  END LOOP;

  RETURN jsonb_build_object('status', 'success', 'rounds', v_out);
END;
$function$;

-- ── 4. Reading and answering as a signed-in user ──────────────────────────────────────────────
--
-- The token functions serve the mailed link. A workshop user opening the order in their own
-- dashboard, or a customer user who has logged in, has a session and no token. Same rounds, same
-- rules; the gate is who they are rather than what they hold.

-- Which of an order's rounds a signed-in user may act on, by audience. NULL = none.
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_round_for_user(p_quotation_id bigint, p_audience text)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT r.approval_round_id
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = p_quotation_id
     AND r.audience = p_audience
     AND (
          qvm_new_apps.is_qparts_team()
       OR (p_audience = 'workshop'
           AND auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id)))
       OR (p_audience = 'client'
           AND EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_users eu
                        WHERE eu.user_id = auth.uid()
                          AND eu.end_customer_id = r.end_customer_id))
     )
   ORDER BY r.approval_round_id DESC
   LIMIT 1;
$function$;

-- The round as this audience sees it. Shares its body with the token read through the token: the
-- token is the round's own credential, so handing it to the token function from inside a SECURITY
-- DEFINER body is the same read with the same audience gate, written once.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_quotation_approval_view(p_quotation_id bigint, p_audience text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint;
  v_token uuid;
  v_view  jsonb;
BEGIN
  IF p_audience NOT IN ('workshop', 'client') THEN
    RAISE EXCEPTION 'Unknown approval audience: %', p_audience;
  END IF;

  v_round := qvm_new_apps.approval_round_for_user(p_quotation_id, p_audience);
  IF v_round IS NULL THEN
    -- Either no round was ever sent, or this user is not its audience. Both read as "nothing to
    -- approve here", and the page says so instead of drawing empty controls.
    RETURN jsonb_build_object('status', 'none');
  END IF;

  -- The token's expiry is for the mailed link. A signed-in user is identified by their session,
  -- so a round they are entitled to does not go dark on them because a link they never used aged
  -- out — the expiry is pushed forward instead. (Which is why this is not STABLE.)
  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET token_expires_at = now() + interval '30 days'
   WHERE r.approval_round_id = v_round AND r.token_expires_at < now();

  SELECT r.access_token INTO v_token
    FROM qvm_new_apps.quotation_approval_rounds r WHERE r.approval_round_id = v_round;

  v_view := qvm_new_apps.get_approval_round_by_token(v_token);
  -- The token itself stays inside: a signed-in user acts through their session, and the page has
  -- no business holding a credential that would also work signed out.
  RETURN v_view || jsonb_build_object(
    'can_decide', (v_view->>'round_status') = 'pending',
    -- A workshop user may also speak for the customer, with evidence. Only while there is a
    -- customer round still open to speak on.
    'can_record_on_behalf', p_audience = 'workshop' AND EXISTS (
       SELECT 1 FROM qvm_new_apps.quotation_approval_rounds c
        WHERE c.quotation_id = p_quotation_id AND c.audience = 'client' AND c.status = 'pending'),
    'client_round_status', (SELECT c.status FROM qvm_new_apps.quotation_approval_rounds c
                             WHERE c.quotation_id = p_quotation_id AND c.audience = 'client'
                             ORDER BY c.approval_round_id DESC LIMIT 1));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.decide_approval_items_as_user(
  p_quotation_id bigint, p_audience text, p_decisions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint := qvm_new_apps.approval_round_for_user(p_quotation_id, p_audience);
  v_token uuid;
BEGIN
  IF v_round IS NULL THEN RAISE EXCEPTION 'This order was not sent to you for approval'; END IF;
  SELECT access_token INTO v_token FROM qvm_new_apps.quotation_approval_rounds WHERE approval_round_id = v_round;
  RETURN qvm_new_apps.decide_approval_items(v_token, p_decisions);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.submit_approval_round_as_user(
  p_quotation_id bigint, p_audience text, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round bigint := qvm_new_apps.approval_round_for_user(p_quotation_id, p_audience);
  v_token uuid;
BEGIN
  IF v_round IS NULL THEN RAISE EXCEPTION 'This order was not sent to you for approval'; END IF;
  SELECT access_token INTO v_token FROM qvm_new_apps.quotation_approval_rounds WHERE approval_round_id = v_round;
  RETURN qvm_new_apps.submit_approval_round(v_token, p_decision, p_note);
END;
$function$;

-- The workshop, having approved its own price, passes the order on to the customer. Same act as
-- the pricing team's send, restricted to the customer audience and to the workshop of that order.
CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_sends_to_client(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_customer bigint;
  v_round    bigint;
  v_count    integer;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_team()
          OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id))) THEN
    RAISE EXCEPTION 'Only the workshop of this order can send it to the customer';
  END IF;

  SELECT q.end_customer_id INTO v_customer FROM qvm_new_apps.quotations q WHERE q.quotation_id = p_quotation_id;
  IF v_customer IS NULL THEN
    RETURN jsonb_build_object('status', 'no_customer',
                              'message', 'This order has no customer to send to');
  END IF;

  SELECT r.approval_round_id INTO v_round
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.quotation_id = p_quotation_id AND r.audience = 'client' AND r.status = 'pending';

  IF v_round IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_approval_rounds (quotation_id, audience, end_customer_id, sent_by)
    VALUES (p_quotation_id, 'client', v_customer, auth.uid())
    RETURNING approval_round_id INTO v_round;
  END IF;

  -- The customer is asked about what the workshop accepted: the lines the workshop's own round
  -- approved, at the selling price. Lines the workshop cancelled are not put to the customer.
  INSERT INTO qvm_new_apps.quotation_approval_items
    (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity)
  SELECT v_round, wi.quotation_item_id, wi.cost_id, wi.wholesale_price, wi.customer_price, wi.quantity
    FROM qvm_new_apps.quotation_approval_items wi
    JOIN qvm_new_apps.quotation_approval_rounds wr ON wr.approval_round_id = wi.approval_round_id
   WHERE wr.quotation_id = p_quotation_id AND wr.audience = 'workshop'
     AND wr.approval_round_id = (SELECT max(approval_round_id) FROM qvm_new_apps.quotation_approval_rounds
                                  WHERE quotation_id = p_quotation_id AND audience = 'workshop')
     AND wi.decision <> 'cancelled'
  ON CONFLICT (approval_round_id, quotation_item_id) DO UPDATE
    SET cost_id = EXCLUDED.cost_id, wholesale_price = EXCLUDED.wholesale_price,
        customer_price = EXCLUDED.customer_price, quantity = EXCLUDED.quantity;

  -- No workshop round at all: fall back to the order's own lines, priced from the best offer.
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    PERFORM qvm_new_apps.send_quotation_for_approval_core(p_quotation_id, 'client', v_round);
  END IF;

  UPDATE qvm_new_apps.quotation_approval_rounds r
     SET total_amount = (SELECT COALESCE(SUM(COALESCE(ai.customer_price, 0) * COALESCE(ai.quantity, 1)), 0)
                           FROM qvm_new_apps.quotation_approval_items ai
                          WHERE ai.approval_round_id = v_round AND ai.decision <> 'cancelled')
   WHERE r.approval_round_id = v_round;

  RETURN jsonb_build_object('status', 'success', 'approval_round_id', v_round,
                            'access_token', (SELECT access_token FROM qvm_new_apps.quotation_approval_rounds
                                              WHERE approval_round_id = v_round));
END;
$function$;

-- The line-filling half of send_quotation_for_approval, callable on its own for the fallback above.
-- Not gated: only ever called from functions that already are.
CREATE OR REPLACE FUNCTION qvm_new_apps.send_quotation_for_approval_core(
  p_quotation_id bigint, p_audience text, p_round bigint)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  INSERT INTO qvm_new_apps.quotation_approval_items
    (approval_round_id, quotation_item_id, cost_id, wholesale_price, customer_price, quantity)
  SELECT p_round, qi.quotation_item_id, best.cost_id, best.cost,
         COALESCE(NULLIF(qi.price_before_vat, 0), best.agency_price), qi.quantity
    FROM qvm_new_apps.quotation_items qi
    LEFT JOIN LATERAL (
      SELECT qvi.cost_id, qvi.cost, qvi.agency_price
        FROM qvm_new_apps.quotation_vendor_items qvi
       WHERE qvi.quotation_item_id = qi.quotation_item_id
         AND qvi.cost IS NOT NULL AND qvi.cost > 0
       ORDER BY qvi.best_cost DESC, qvi.cost ASC
       LIMIT 1
    ) best ON true
   WHERE qi.quotation_id = p_quotation_id
     AND qi.item_status NOT IN (
       SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
        WHERE ld.list_id = 3
          AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
  ON CONFLICT (approval_round_id, quotation_item_id) DO NOTHING;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.send_quotation_for_approval_core(bigint, text, bigint) FROM PUBLIC;

-- ── 5. Who to tell ────────────────────────────────────────────────────────────────────────────
--
-- Email goes out from the page through the resend-notify function, the way every other mail in
-- this app does; this only answers who. Workshop: the client-side users of the order's company and
-- branch. Client: the users attached to the order's end customer, and the customer's own contact
-- email when it has one and no user does.
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_recipients(p_quotation_id bigint, p_audience text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT CASE
    WHEN NOT (qvm_new_apps.is_qparts_team()
              OR auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id)))
      THEN '[]'::jsonb
    WHEN p_audience = 'workshop' THEN COALESCE((
      SELECT jsonb_agg(DISTINCT jsonb_build_object('email', ud.email, 'name', ud.user_name))
        FROM qvm_new_apps.user_data ud
       WHERE ud.user_id IN (SELECT qvm_new_apps.workshop_users_for_quotation(p_quotation_id))
         AND COALESCE(btrim(ud.email), '') <> ''), '[]'::jsonb)
    ELSE COALESCE((
      SELECT jsonb_agg(DISTINCT x) FROM (
        SELECT jsonb_build_object('email', ud.email, 'name', ud.user_name) AS x
          FROM qvm_new_apps.quotations q
          JOIN qvm_new_apps.end_customer_users eu ON eu.end_customer_id = q.end_customer_id
          JOIN qvm_new_apps.user_data ud ON ud.user_id = eu.user_id AND ud.deleted_at IS NULL
         WHERE q.quotation_id = p_quotation_id AND COALESCE(btrim(ud.email), '') <> ''
        UNION
        SELECT jsonb_build_object('email', ec.email, 'name', COALESCE(ec.contact_person, ec.name))
          FROM qvm_new_apps.quotations q
          JOIN qvm_new_apps.end_customers ec ON ec.end_customer_id = q.end_customer_id
         WHERE q.quotation_id = p_quotation_id AND COALESCE(btrim(ec.email), '') <> ''
           AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_users eu2
                            WHERE eu2.end_customer_id = q.end_customer_id)
      ) s), '[]'::jsonb)
  END;
$function$;

-- ── 6. The customer's own list ────────────────────────────────────────────────────────────────
--
-- What a signed-in customer user sees: the orders they were named on that have been put to them,
-- newest first, with where each stands. Orders that were never sent are not theirs to see yet.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_my_customer_approvals()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'quotation_id',  q.quotation_id,
             'order_number',  q.order_number,
             'plate_number',  q.plate_number,
             'created_at',    q.created_at,
             'sent_at',       r.sent_at,
             'round_status',  r.status,
             'total_amount',  r.total_amount,
             'items',         (SELECT count(*) FROM qvm_new_apps.quotation_approval_items ai
                                WHERE ai.approval_round_id = r.approval_round_id),
             'customer_name', vec.name,
             'vehicle', (SELECT concat_ws(' ', ld.list_data, qi.model, qi.year)
                           FROM qvm_new_apps.quotation_items qi
                           LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.main_brand
                          WHERE qi.quotation_id = q.quotation_id
                          ORDER BY qi.quotation_item_id LIMIT 1))
           ORDER BY r.sent_at DESC)
      FROM qvm_new_apps.quotation_approval_rounds r
      JOIN qvm_new_apps.quotations q ON q.quotation_id = r.quotation_id
      JOIN qvm_new_apps.end_customer_users eu
        ON eu.end_customer_id = r.end_customer_id AND eu.user_id = auth.uid()
      LEFT JOIN qvm_new_apps.v_end_customers vec ON vec.end_customer_id = r.end_customer_id
     WHERE r.audience = 'client'
       AND r.approval_round_id = (SELECT max(r2.approval_round_id)
                                    FROM qvm_new_apps.quotation_approval_rounds r2
                                   WHERE r2.quotation_id = r.quotation_id AND r2.audience = 'client')),
    '[]'::jsonb);
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_end_customers_for_order(p_workshop_id bigint DEFAULT NULL, p_branch_id integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_end_customers_for_order(p_workshop_id, p_branch_id); $$;
CREATE OR REPLACE FUNCTION public.get_quotation_approval_view(p_quotation_id bigint, p_audience text)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.get_quotation_approval_view(p_quotation_id, p_audience); $$;
CREATE OR REPLACE FUNCTION public.decide_approval_items_as_user(p_quotation_id bigint, p_audience text, p_decisions jsonb)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.decide_approval_items_as_user(p_quotation_id, p_audience, p_decisions); $$;
CREATE OR REPLACE FUNCTION public.submit_approval_round_as_user(p_quotation_id bigint, p_audience text, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.submit_approval_round_as_user(p_quotation_id, p_audience, p_decision, p_note); $$;
CREATE OR REPLACE FUNCTION public.workshop_sends_to_client(p_quotation_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.workshop_sends_to_client(p_quotation_id); $$;
CREATE OR REPLACE FUNCTION public.approval_recipients(p_quotation_id bigint, p_audience text)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.approval_recipients(p_quotation_id, p_audience); $$;
CREATE OR REPLACE FUNCTION public.list_my_customer_approvals()
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_my_customer_approvals(); $$;

REVOKE ALL ON FUNCTION public.list_end_customers_for_order(bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quotation_approval_view(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_approval_items_as_user(bigint, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_approval_round_as_user(bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.workshop_sends_to_client(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approval_recipients(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_customer_approvals() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_end_customers_for_order(bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_quotation_approval_view(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.decide_approval_items_as_user(bigint, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.submit_approval_round_as_user(bigint, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.workshop_sends_to_client(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approval_recipients(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_customer_approvals() TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_end_customers_for_order(bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.approval_round_for_user(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_quotation_approval_view(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.decide_approval_items_as_user(bigint, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.submit_approval_round_as_user(bigint, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.workshop_sends_to_client(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.approval_recipients(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_my_customer_approvals() TO authenticated, service_role;
