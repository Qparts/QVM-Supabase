-- Warehouse receiving: per-item receipt status (Received / Lower Quantity / Wrong Part / Not
-- Received), captured in signed, immutable "rounds" so a PO can be received in multiple passes
-- with a full audit trail. purchase_items.receipt_status/received_qty always mirror the LATEST
-- round; purchase_receipt_rounds/_items hold the append-only history.

ALTER TABLE qvm_new_apps.purchase_items
  ADD COLUMN IF NOT EXISTS receipt_status text
    CHECK (receipt_status IN ('received','lower_qty','wrong_part','not_received')),
  ADD COLUMN IF NOT EXISTS receipt_status_updated_at timestamptz,
  ADD COLUMN IF NOT EXISTS receipt_status_updated_by uuid REFERENCES qvm_new_apps.user_data(user_id);

COMMENT ON COLUMN qvm_new_apps.purchase_items.receipt_status IS
  'Warehouse receiving status (current/latest), independent of the legacy vendor_item_status
   (157-161 vendor-RFQ pipeline enum, unrelated). NULL = not yet processed by receiving.
   Always mirrors the newest purchase_receipt_round_items snapshot for this item.';
COMMENT ON COLUMN qvm_new_apps.purchase_items.received_qty IS
  'Actual quantity physically received, entered by whoever signs the receiving round.
   Meaningful mainly when receipt_status = lower_qty.';

CREATE TABLE IF NOT EXISTS qvm_new_apps.purchase_receipt_rounds (
  receipt_round_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  purchase_order_id bigint NOT NULL REFERENCES qvm_new_apps.purchase_orders(purchase_order_id),
  round_no          int NOT NULL,
  signed_by         uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id),
  signed_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, round_no)
);

CREATE TABLE IF NOT EXISTS qvm_new_apps.purchase_receipt_round_items (
  receipt_round_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  receipt_round_id  bigint NOT NULL REFERENCES qvm_new_apps.purchase_receipt_rounds(receipt_round_id) ON DELETE CASCADE,
  purchase_item_id  bigint NOT NULL REFERENCES qvm_new_apps.purchase_items(purchase_item_id),
  receipt_status    text NOT NULL CHECK (receipt_status IN ('received','lower_qty','wrong_part','not_received')),
  received_qty      int,
  UNIQUE (receipt_round_id, purchase_item_id)
);

CREATE INDEX IF NOT EXISTS idx_prr_po ON qvm_new_apps.purchase_receipt_rounds(purchase_order_id, round_no DESC);
CREATE INDEX IF NOT EXISTS idx_prri_round ON qvm_new_apps.purchase_receipt_round_items(receipt_round_id);
CREATE INDEX IF NOT EXISTS idx_prri_item ON qvm_new_apps.purchase_receipt_round_items(purchase_item_id, receipt_round_id DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_items_po ON qvm_new_apps.purchase_items(purchase_order_id);

GRANT SELECT, INSERT ON qvm_new_apps.purchase_receipt_rounds TO authenticated;
GRANT SELECT, INSERT ON qvm_new_apps.purchase_receipt_round_items TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA qvm_new_apps TO authenticated;

-- Who can view/sign receiving for a given PO: any internal user (185), or a client user (183)
-- scoped to their own branch/company, mirroring can_access_note_record's existing client-scoping
-- logic for confirmed_orders exactly.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_access_purchase_order(p_purchase_order_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_confirmed_order_id integer;
BEGIN
  SELECT confirmed_order_id INTO v_confirmed_order_id
  FROM qvm_new_apps.purchase_orders WHERE purchase_order_id = p_purchase_order_id;

  IF v_confirmed_order_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN qvm_new_apps.can_access_note_record('confirmed_orders', v_confirmed_order_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.can_access_purchase_order(bigint) TO authenticated;

-- PO-level list for the restructured #/purchase-invoices table: one row per purchase_order_id,
-- with aggregated item counts, value, and receipt-status pill counts. Mirrors
-- get_purchase_invoices_dashboard's own visibility scoping (internal / client company-admin /
-- client own-branch) so the same page's access rules stay consistent.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(
  p_user_id uuid,
  p_is_manager boolean DEFAULT false,
  p_search text DEFAULT NULL,
  p_branch_ids int[] DEFAULT NULL,
  p_supplier_ids int[] DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0
)
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
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id))
       OR (uc.user_role <> 170 AND first_branch.customer_id = uc.user_branch)
  ),
  po_agg AS (
    SELECT pi.purchase_order_id,
      count(*)                                                                        AS item_count,
      count(*) FILTER (WHERE pi.receipt_status = 'received')                          AS received_count,
      count(*) FILTER (WHERE pi.receipt_status = 'lower_qty')                         AS lower_qty_count,
      count(*) FILTER (WHERE pi.receipt_status = 'wrong_part')                        AS wrong_part_count,
      count(*) FILTER (WHERE pi.receipt_status IS NULL OR pi.receipt_status = 'not_received') AS not_received_count,
      sum(COALESCE(pi.approved_qty, 0))                                              AS total_approved_qty,
      sum(COALESCE(pi.final_purchase_price, 0) * COALESCE(pi.approved_qty, 0))       AS total_value
    FROM qvm_new_apps.purchase_items pi
    WHERE pi.purchase_order_id IS NOT NULL
    GROUP BY pi.purchase_order_id
  ),
  base AS (
    SELECT
      po.purchase_order_id,
      ('PO-' || po.purchase_order_id) AS po_number,
      q.order_number,
      co.created_at AS confirmation_date,
      vnd.vendor_name,
      po.vendor_id,
      cb.branch_name,
      first_branch.customer_id,
      a.item_count, a.received_count, a.lower_qty_count, a.wrong_part_count, a.not_received_count,
      a.total_approved_qty, a.total_value
    FROM qvm_new_apps.purchase_orders po
    JOIN po_agg a ON a.purchase_order_id = po.purchase_order_id
    JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
    JOIN order_scope os ON os.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
    LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
    LEFT JOIN LATERAL (
      SELECT qi.customer_id FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = q.quotation_id ORDER BY qi.quotation_item_id ASC LIMIT 1
    ) first_branch ON true
    LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = first_branch.customer_id
  ),
  filtered AS (
    SELECT * FROM base b
    WHERE (p_search IS NULL OR p_search = '' OR b.order_number ILIKE '%'||p_search||'%' OR b.vendor_name ILIKE '%'||p_search||'%' OR b.po_number ILIKE '%'||p_search||'%')
      AND (COALESCE(array_length(v_branch_ids,1),0) = 0 OR b.customer_id = ANY(v_branch_ids))
      AND (COALESCE(array_length(v_supplier_ids,1),0) = 0 OR b.vendor_id = ANY(v_supplier_ids))
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'total', (SELECT count(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.confirmation_date DESC) FROM (
        SELECT * FROM filtered ORDER BY confirmation_date DESC LIMIT p_limit OFFSET p_offset
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_purchase_orders_receipt_dashboard(uuid, boolean, text, int[], int[], int, int) TO authenticated;

-- Full detail for the receiving modal: current item statuses + full signed-round history with
-- attachments, for one PO.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_purchase_order_receipt_detail(p_purchase_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.can_access_purchase_order(p_purchase_order_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', null);
  END IF;

  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'po_number', 'PO-' || po.purchase_order_id,
      'order_number', q.order_number,
      'vendor_name', vnd.vendor_name,

      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'purchase_item_id', pi.purchase_item_id,
          'confirmed_item_id', pi.confirmed_item_id,
          'part_description', qi.part_description,
          'final_part_number', ci.final_part_number,
          'approved_qty', pi.approved_qty,
          'receipt_status', pi.receipt_status,
          'received_qty', pi.received_qty,
          'updated_at', pi.receipt_status_updated_at,
          'updated_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = pi.receipt_status_updated_by)
        ) ORDER BY pi.purchase_item_id)
        FROM qvm_new_apps.purchase_items pi
        JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        WHERE pi.purchase_order_id = po.purchase_order_id
      ), '[]'::jsonb),

      'rounds', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'receipt_round_id', r.receipt_round_id,
          'round_no', r.round_no,
          'signed_by_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = r.signed_by),
          'signed_at', r.signed_at,
          'items', (
            SELECT jsonb_agg(jsonb_build_object(
              'purchase_item_id', ri.purchase_item_id,
              'receipt_status', ri.receipt_status,
              'received_qty', ri.received_qty
            ) ORDER BY ri.purchase_item_id)
            FROM qvm_new_apps.purchase_receipt_round_items ri WHERE ri.receipt_round_id = r.receipt_round_id
          ),
          'item_photos', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', f.id, 'file_path', f.file_path, 'created_at', f.created_at))
            FROM qvm_new_apps.files f WHERE f.module_type = 'purchase_receipt_round' AND f.module_id = r.receipt_round_id AND f.field_id = 'item_photos'
          ), '[]'::jsonb),
          'receipt_attachments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', f.id, 'file_path', f.file_path, 'created_at', f.created_at))
            FROM qvm_new_apps.files f WHERE f.module_type = 'purchase_receipt_round' AND f.module_id = r.receipt_round_id AND f.field_id = 'receipt_attachment'
          ), '[]'::jsonb)
        ) ORDER BY r.round_no DESC)
        FROM qvm_new_apps.purchase_receipt_rounds r WHERE r.purchase_order_id = po.purchase_order_id
      ), '[]'::jsonb)
    )
  )
  FROM qvm_new_apps.purchase_orders po
  JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = po.confirmed_order_id
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  LEFT JOIN qvm_new_apps.vendors vnd ON vnd.vendor_id = po.vendor_id
  WHERE po.purchase_order_id = p_purchase_order_id
  INTO v_result;

  RETURN COALESCE(v_result, jsonb_build_object('status', false, 'message', 'Purchase order not found', 'data', null));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_purchase_order_receipt_detail(bigint) TO authenticated;

-- Saves one signed receiving round: snapshots every item on the PO (payload values for changed
-- items, carried-forward current values for the rest), then updates purchase_items' current
-- columns to match — only bumping the updated_at/_by stamp where the value actually changed.
CREATE OR REPLACE FUNCTION qvm_new_apps.save_purchase_receipt_round(
  p_purchase_order_id bigint,
  p_items jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round_id bigint;
  v_round_no int;
BEGIN
  IF NOT qvm_new_apps.can_access_purchase_order(p_purchase_order_id) THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', null);
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_items must be a non-empty JSON array', 'data', null);
  END IF;

  SELECT COALESCE(max(round_no), 0) + 1 INTO v_round_no
  FROM qvm_new_apps.purchase_receipt_rounds WHERE purchase_order_id = p_purchase_order_id;

  INSERT INTO qvm_new_apps.purchase_receipt_rounds (purchase_order_id, round_no, signed_by)
  VALUES (p_purchase_order_id, v_round_no, auth.uid())
  RETURNING receipt_round_id INTO v_round_id;

  INSERT INTO qvm_new_apps.purchase_receipt_round_items (receipt_round_id, purchase_item_id, receipt_status, received_qty)
  SELECT v_round_id, pi.purchase_item_id,
         COALESCE(upd.receipt_status, pi.receipt_status, 'not_received'),
         COALESCE((upd.received_qty)::int, pi.received_qty)
  FROM qvm_new_apps.purchase_items pi
  LEFT JOIN LATERAL (
    SELECT (e->>'receipt_status') AS receipt_status, (e->>'received_qty') AS received_qty
    FROM jsonb_array_elements(p_items) e
    WHERE (e->>'purchase_item_id')::bigint = pi.purchase_item_id
  ) upd ON true
  WHERE pi.purchase_order_id = p_purchase_order_id;

  UPDATE qvm_new_apps.purchase_items pi SET
    receipt_status_updated_at = CASE WHEN ri.receipt_status IS DISTINCT FROM pi.receipt_status OR ri.received_qty IS DISTINCT FROM pi.received_qty THEN now() ELSE pi.receipt_status_updated_at END,
    receipt_status_updated_by = CASE WHEN ri.receipt_status IS DISTINCT FROM pi.receipt_status OR ri.received_qty IS DISTINCT FROM pi.received_qty THEN auth.uid() ELSE pi.receipt_status_updated_by END,
    receipt_status = ri.receipt_status,
    received_qty = ri.received_qty
  FROM qvm_new_apps.purchase_receipt_round_items ri
  WHERE ri.receipt_round_id = v_round_id AND ri.purchase_item_id = pi.purchase_item_id;

  RETURN jsonb_build_object('status', true, 'message', 'Receipt round saved',
    'data', jsonb_build_object('receipt_round_id', v_round_id, 'round_no', v_round_no, 'purchase_order_id', p_purchase_order_id));
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.save_purchase_receipt_round(bigint, jsonb) TO authenticated;

-- Extend get_purchase_invoices_dashboard with an optional PO filter, so the expanded row / modal
-- can fetch just one PO's items instead of the whole page's item dataset.
DROP FUNCTION IF EXISTS public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int);

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_dashboard(
  p_user_id uuid,
  p_is_manager boolean DEFAULT false,
  p_search text DEFAULT NULL::text,
  p_missing_pi boolean DEFAULT false,
  p_missing_rn boolean DEFAULT false,
  p_account_manager uuid DEFAULT NULL::uuid,
  p_branch_ids integer[] DEFAULT NULL::integer[],
  p_supplier_ids integer[] DEFAULT NULL::integer[],
  p_limit integer DEFAULT 200,
  p_offset integer DEFAULT 0,
  p_purchase_order_id bigint DEFAULT NULL
)
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
       OR (uc.user_role = 170 AND EXISTS (SELECT 1 FROM qvm_new_apps.client_branches cb WHERE cb.list_data_id = uc.company AND cb.customer_id = first_branch.customer_id))
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

GRANT EXECUTE ON FUNCTION public.get_purchase_invoices_dashboard(uuid, boolean, text, boolean, boolean, uuid, int[], int[], int, int, bigint) TO authenticated;
