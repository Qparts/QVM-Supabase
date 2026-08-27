-- Internal branch-scoped sub-users.
--
-- Today every user_type = 185 (Qparts Team) account has unrestricted, platform-wide visibility —
-- confirmed live: 63 distinct functions gate access with a blanket "user_type = 185 => full access"
-- check, with no company/branch filtering at all. This migration introduces a new access model:
--
--   1. user_role = 'Qparts Admin' (172)        -> unrestricted, unchanged from today.
--   2. every other internal role (existing     -> restricted to exactly the branches assigned to
--      Account Manager / Purchasing / Part        them in qvm_new_apps.internal_user_branches.
--      Number Extractor accounts, and the new      No rows assigned = sees nothing (no fallback
--      "Internal Branch User" role)                to whole-company visibility).
--
-- This is a deliberate, confirmed behavior change for *existing* non-admin internal accounts, not
-- just new sub-users — they will see nothing until a Qparts Admin assigns them branches.
--
-- Only get_internal_dashboard and get_internal_actions (the Internal Dashboard's RFQs/Orders/
-- Actions tabs) are retrofitted here. The other ~60 functions that check user_type = 185 (Vendors
-- dashboard, Purchase Invoices, Delivered Orders, Account Managers, the older rfq_dashboard_paged,
-- etc.) are unchanged for now — same phased approach as the rest of this session's work — and need
-- the same get_internal_branch_scope() call added in a follow-up pass before a branch-scoped user
-- can be pointed at those pages.

-- 1. New user_role: "Internal Branch User" (list_id = 16, next free id after 270 = 271).
-- list_data_id is GENERATED ALWAYS AS IDENTITY, so an explicit value needs OVERRIDING SYSTEM VALUE.
INSERT INTO qvm_new_apps.list_data (list_data_id, list_id, list_data)
OVERRIDING SYSTEM VALUE
VALUES (271, 16, 'Internal Branch User')
ON CONFLICT (list_data_id) DO NOTHING;

-- 2. Branch assignment table — same shape as the existing vendor_branch_users pattern.
CREATE TABLE IF NOT EXISTS qvm_new_apps.internal_user_branches (
  user_id uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id),
  branch_id integer NOT NULL REFERENCES qvm_new_apps.client_branches(customer_id),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NULL,
  UNIQUE (user_id, branch_id)
);

CREATE INDEX IF NOT EXISTS idx_internal_user_branches_user ON qvm_new_apps.internal_user_branches (user_id);

-- 3. Scope helper: NULL = unrestricted (Qparts Admin), otherwise the assigned branch id array
-- (possibly empty, meaning "sees nothing yet").
CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_branch_scope(p_user_id uuid)
 RETURNS integer[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN (SELECT user_role FROM qvm_new_apps.user_data WHERE user_id = p_user_id) = 172 THEN NULL
    ELSE COALESCE(
      (SELECT array_agg(branch_id) FROM qvm_new_apps.internal_user_branches WHERE user_id = p_user_id),
      ARRAY[]::integer[]
    )
  END;
$function$;

-- 4. Retrofit get_internal_dashboard: add the branch-scope filter alongside the existing
-- user_type = 185 gate.
DROP FUNCTION IF EXISTS public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], bigint[], text, text, integer, integer, integer[]);

CREATE FUNCTION public.get_internal_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_account_managers uuid[] DEFAULT NULL::uuid[], p_clients integer[] DEFAULT NULL::integer[], p_branches integer[] DEFAULT NULL::integer[], p_brands integer[] DEFAULT NULL::integer[], p_statuses integer[] DEFAULT NULL::integer[], p_insurance_company_ids bigint[] DEFAULT NULL::bigint[], p_mode text DEFAULT 'regular'::text, p_view text DEFAULT 'rfqs'::text, p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0, p_quotation_ids integer[] DEFAULT NULL::integer[])
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
  v_order_statuses int[] := ARRAY[19, 21, 22, 23];
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
      ic.name AS insurance_company_name
    FROM filtered_quotations fq
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = fq.customer_id
    LEFT JOIN qvm_new_apps.list_data ld_client ON ld_client.list_data_id = cb.list_data_id
    LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = fq.insurance_company_id
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
$function$
;

GRANT EXECUTE ON FUNCTION public.get_internal_dashboard(uuid, text, timestamptz, timestamptz, uuid[], integer[], integer[], integer[], integer[], bigint[], text, text, integer, integer, integer[]) TO authenticated;

-- 5. Retrofit get_internal_actions: same branch-scope filter added to each of the 4 buckets.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_internal_actions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_delay_days int;
  v_ready jsonb; v_fully jsonb; v_sla jsonb; v_nopo jsonb;
  c_closed int[] := array[18, 23, 29, 30, 31, 268];
  c_less_than_priced int[] := array[216, 217, 218, 235, 236, 237];
  v_branch_scope integer[];
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', null);
  end if;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  -- report_settings_thresholds.value is numeric
  select value::int into v_delay_days
  from qvm_new_apps.report_settings_thresholds where key = 'order_delay_threshold_days';
  v_delay_days := coalesce(v_delay_days, 3);

  select coalesce(jsonb_agg(to_jsonb(r) order by r.rfq_date desc), '[]'::jsonb) into v_ready
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) as item_count
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where qi.item_status = 235
      and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.rfq_date desc), '[]'::jsonb) into v_fully
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) filter (where qi.item_status = any(c_less_than_priced)) as sent_count,
           count(*) filter (where qi.item_status = any(c_less_than_priced) and exists (
             select 1 from qvm_new_apps.quotation_vendor_items qvi
             where qvi.quotation_item_id = qi.quotation_item_id and qvi.cost is not null and qvi.cost > 0
           )) as priced_count
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
    having count(*) filter (where qi.item_status = any(c_less_than_priced)) > 0
       and count(*) filter (where qi.item_status = any(c_less_than_priced)) = count(*) filter (where qi.item_status = any(c_less_than_priced) and exists (
             select 1 from qvm_new_apps.quotation_vendor_items qvi
             where qvi.quotation_item_id = qi.quotation_item_id and qvi.cost is not null and qvi.cost > 0
           ))
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.age_days desc), '[]'::jsonb) into v_sla
  from (
    select q.quotation_id, q.order_number, q.created_at as rfq_date,
           coalesce(cb.branch_name, '') as branch_name,
           count(*) as open_items,
           floor(extract(epoch from (now() - q.created_at)) / 86400)::int as age_days
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where not (qi.item_status = any(c_closed))
      and q.created_at < now() - make_interval(days => v_delay_days)
      and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
    group by q.quotation_id, q.order_number, q.created_at, cb.branch_name
  ) r;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.confirmation_date desc), '[]'::jsonb) into v_nopo
  from (
    select q.quotation_id, co.confirmed_order_id, q.order_number,
           co.created_at as confirmation_date,
           coalesce(cb.branch_name, '') as branch_name,
           (select count(*) from qvm_new_apps.confirmed_items ci where ci.confirmed_order_id = co.confirmed_order_id) as item_count
    from qvm_new_apps.confirmed_orders co
    join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
    left join lateral (
      select cb2.customer_id, cb2.branch_name
      from qvm_new_apps.quotation_items qi2
      join qvm_new_apps.client_branches cb2 on cb2.customer_id = qi2.customer_id
      where qi2.quotation_id = q.quotation_id
      limit 1
    ) cb on true
    where not exists (
      select 1 from qvm_new_apps.purchase_orders po
      where po.confirmed_order_id = co.confirmed_order_id
    )
    and (v_branch_scope is null or cb.customer_id = any(v_branch_scope))
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'sla_threshold_days', v_delay_days,
    'ready_for_quotation', v_ready,
    'fully_priced', v_fully,
    'exceeded_sla', v_sla,
    'confirmed_no_po', v_nopo
  ));
end $function$
;
