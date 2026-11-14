-- Purchase orders: a line is bought once, and can be taken off its purchase order.
--
-- The pricing page reopened with every line already on a purchase order selected, so the next
-- Create Purchase Order bought them all again: 417 lines on QVM/test sit on two or three vendor
-- purchase orders. The page no longer does that, and create_purchase_orders_anditems now refuses
-- any line already on a vendor purchase order.
--
-- remove_item_from_purchase_order takes one line off one purchase order (Purchase Invoices page).
-- The line goes back to Confirmed, ready for a new purchase order, unless another vendor purchase
-- order still has it. That return to Confirmed sends no notification: dispatch_notification_rules
-- and wa_note_quote_superseded stay quiet while qvm.status_back_from_po is set, which only this
-- function does, for its own transaction.
--
-- get_purchase_invoices_dashboard adds purchase_order_id (the purchase order the row shows) and
-- po_count. Every other function body is the live one on QVM/test with only the changes shown.

CREATE OR REPLACE FUNCTION qvm_new_apps.create_purchase_orders_anditems(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  results JSONB := '[]'::jsonb;
  v_already text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', false,
      'message', 'p_items must be a JSON array'
    );
  END IF;

  -- The same line twice in one call would buy it twice.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    GROUP BY e->>'confirmed_item_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'The same item is in this purchase order twice';
  END IF;

  -- Hold the lines, so two purchase orders raised at the same moment can't both get past the
  -- check below: the second waits here, then sees the first one's lines.
  PERFORM 1 FROM qvm_new_apps.confirmed_items ci
  WHERE ci.confirmed_item_id IN (
    SELECT NULLIF(e->>'confirmed_item_id','')::INT FROM jsonb_array_elements(p_items) e
  )
  FOR UPDATE;

  -- A line already bought from a vendor is not bought again. It has to come off its purchase
  -- order first (Purchase Invoices page). Uploading an invoice makes a purchase order with no
  -- vendor; that one isn't a purchase and doesn't count.
  SELECT string_agg(DISTINCT
           COALESCE(NULLIF(btrim(qi.part_number), ''), NULLIF(btrim(qi.part_description), ''), 'item ' || ci.confirmed_item_id)
           || ' (PO ' || po.purchase_order_id || ')', ', ')
  INTO v_already
  FROM jsonb_array_elements(p_items) e
  JOIN qvm_new_apps.purchase_items pi ON pi.confirmed_item_id = NULLIF(e->>'confirmed_item_id','')::INT
  JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id AND po.vendor_id IS NOT NULL
  JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
  LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id;

  IF v_already IS NOT NULL THEN
    RAISE EXCEPTION 'Already on a purchase order: %. Remove it from that purchase order on the Purchase Invoices page first.', v_already;
  END IF;

  WITH distinct_vendors AS (
    SELECT DISTINCT
      (e->>'vendor_id')::INT AS vendor_id,
      NULLIF(e->>'vendor_branch_id','')::BIGINT AS vendor_branch_id,
      (e->>'confirmed_order_id')::INT AS confirmed_order_id
    FROM jsonb_array_elements(p_items) e
    WHERE NULLIF(e->>'vendor_id','') IS NOT NULL
  ),
  inserted_orders AS (
    INSERT INTO qvm_new_apps.purchase_orders (vendor_id, vendor_branch_id, confirmed_order_id, vendor_status, created_at)
    SELECT vendor_id, vendor_branch_id, confirmed_order_id, 159, NOW()
    FROM distinct_vendors
    RETURNING purchase_order_id, confirmed_order_id, vendor_id, vendor_branch_id
  ),
  inserted_items AS (
    INSERT INTO qvm_new_apps.purchase_items (
      purchase_order_id,
      confirmed_item_id,
      cost_id,
      approved_qty,
      vendor_item_status,
      vendor_shipping_cost,
      created_at
    )
    SELECT
      po.purchase_order_id,
      NULLIF(e->>'confirmed_item_id','')::INT,
      NULLIF(e->>'cost_id','')::INT,
      NULLIF(e->>'approved_qty','')::INT,
      159,
      COALESCE(NULLIF(e->>'vendor_shipping_cost','')::double precision, 0),
      NOW()
    FROM jsonb_array_elements(p_items) e
    JOIN inserted_orders po
      ON (e->>'confirmed_order_id')::INT = po.confirmed_order_id
     AND (e->>'vendor_id')::INT = po.vendor_id
     AND NULLIF(e->>'vendor_branch_id','')::BIGINT IS NOT DISTINCT FROM po.vendor_branch_id
    WHERE NULLIF(e->>'confirmed_item_id','') IS NOT NULL
    RETURNING purchase_item_id, purchase_order_id, confirmed_item_id, cost_id
  ),
  status_update AS (
    UPDATE qvm_new_apps.confirmed_items ci
    SET item_status = 21, updated_at = NOW()
    FROM inserted_items ii
    WHERE ci.confirmed_item_id = ii.confirmed_item_id
    RETURNING ci.confirmed_item_id, ci.quotation_item_id
  ),
  -- Save cost_id back to quotation_items so it can be restored when reopening pricing modal
  cost_id_update AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET cost_id = ii.cost_id, updated_at = NOW()
    FROM inserted_items ii
    JOIN status_update su ON su.confirmed_item_id = ii.confirmed_item_id
    WHERE qi.quotation_item_id = su.quotation_item_id
      AND ii.cost_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'purchase_order_id', po.purchase_order_id,
      'confirmed_order_id', po.confirmed_order_id,
      'vendor_id', po.vendor_id,
      'vendor_branch_id', po.vendor_branch_id,
      'purchase_item_id', pi.purchase_item_id,
      'confirmed_item_id', pi.confirmed_item_id,
      'status', true
    )
  ), '[]'::jsonb)
  INTO results
  FROM inserted_orders po
  JOIN inserted_items pi ON pi.purchase_order_id = po.purchase_order_id
  JOIN status_update su ON su.confirmed_item_id = pi.confirmed_item_id;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk insert processed',
    'count', jsonb_array_length(p_items),
    'data', results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_purchase_invoices_dashboard(p_user_id uuid, p_is_manager boolean DEFAULT false, p_search text DEFAULT NULL::text, p_missing_pi boolean DEFAULT false, p_missing_rn boolean DEFAULT false, p_account_manager uuid DEFAULT NULL::uuid, p_branch_ids integer[] DEFAULT NULL::integer[], p_supplier_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
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
      po.uploaded_by AS invoice_uploaded_by,
      -- Who raised the PO. Falls back to uploaded_by for orders created before
      -- send_po_webhook replayed its caller's identity onto the connection.
      COALESCE(po.created_by, po.uploaded_by) AS po_created_by,
      po.created_at AS po_created_at,
      count(*) OVER (PARTITION BY pi.confirmed_item_id) AS po_count
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
      lpo.vendor_invoice_url,
      lpo.vendor_invoice_number,
      lpo.zoho_bill_url,
      lpo.invoice_uploaded_by,
      lpo.po_created_by,
      lpo.po_created_at,
      lpo.purchase_order_id,
      lpo.po_count,
      lvcn.creditnote_uploaded_by,
      lvcn.vendor_creditnote_url,
      ao.invoice_attachments,
      vao.vendor_creditnote_attachments,
      ld.status_changed_by AS delivered_by,
      uc.is_internal AS is_internal_user
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
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = invoice_uploaded_by) AS invoice_uploaded_by_name,
          (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = po_created_by) AS po_created_by_name,
          po_created_at,
          purchase_order_id,
          COALESCE(po_count, 0) AS po_count,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.dispatch_notification_rules(p_quotation_item_id integer, p_new_status_id integer, p_source_table text DEFAULT 'quotation_items'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_order_number text;
  v_quotation_id integer;
  v_client_name text;
  v_part_name text;
  v_status_name text;
  v_account_manager uuid;
  v_company_id integer;
  v_webhook_base_url text;
  v_rule record;
  v_message text;
  v_recipient_id uuid;
  v_dispatched_ids uuid[];
  -- 'Priced' (17) on a not-yet-confirmed item is specifically "vendor pricing needs review on the
  -- comparison page" — an internal-only workflow step, hence only applied to internal recipients.
  v_internal_nav_target text;
  v_client_nav_target text;
BEGIN
  -- Set (for the current transaction only) by remove_item_from_purchase_order: the line went back
  -- to Confirmed because it came off its purchase order, not because anyone confirmed it.
  IF current_setting('qvm.status_back_from_po', true) = 'on' THEN
    RETURN;
  END IF;

  SELECT q.order_number, q.quotation_id, q.account_manager, qi.part_description, ld.list_data, cb.list_data_id
  INTO v_order_number, v_quotation_id, v_account_manager, v_part_name, v_client_name, v_company_id
  FROM qvm_new_apps.quotation_items qi
  JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
  LEFT JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = cb.list_data_id
  WHERE qi.quotation_item_id = p_quotation_item_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT list_data INTO v_status_name FROM qvm_new_apps.list_data WHERE list_data_id = p_new_status_id;
  IF v_company_id IS NOT NULL THEN
    SELECT webhook_base_url INTO v_webhook_base_url FROM qvm_new_apps.notification_settings WHERE company_id = v_company_id;
  END IF;

  v_client_nav_target := CASE WHEN p_source_table = 'confirmed_items' THEN 'orders' ELSE 'rfqs' END;
  v_internal_nav_target := CASE
    WHEN p_source_table = 'confirmed_items' THEN 'orders'
    WHEN p_new_status_id = 17 THEN 'pricing'
    ELSE 'rfqs'
  END;

  FOR v_rule IN
    SELECT * FROM qvm_new_apps.notification_rules
    WHERE trigger_type = 'status_change'
      AND trigger_status_id = p_new_status_id
      AND delay_hours = 0
      AND is_active
  LOOP
    v_message := v_rule.message_template;
    v_message := replace(v_message, '{order_id}', COALESCE(v_order_number, ''));
    v_message := replace(v_message, '{rfq_id}', COALESCE(v_order_number, ''));
    v_message := replace(v_message, '{client_name}', COALESCE(v_client_name, ''));
    v_message := replace(v_message, '{part_name}', COALESCE(v_part_name, ''));
    v_message := replace(v_message, '{link}', '');
    v_message := replace(v_message, '{deadline}', '');

    IF 'browser_push' = ANY(v_rule.channels) THEN
      v_dispatched_ids := ARRAY[]::uuid[];
      IF v_rule.recipient_type = 'client' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_client_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id,
              'nav_target', v_client_nav_target, 'order_number', v_order_number));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      ELSIF v_rule.recipient_type = 'vendor' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_vendor_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id,
              'nav_target', 'vendor-quotation', 'order_number', v_order_number));
        END LOOP;
      ELSIF v_rule.recipient_type = 'internal_role' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_internal_role_recipients(v_rule.recipient_role_id, v_account_manager) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id,
              'nav_target', v_internal_nav_target, 'order_number', v_order_number));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      END IF;

      IF v_rule.recipient_type != 'vendor' AND v_company_id IS NOT NULL THEN
        FOR v_recipient_id IN
          SELECT u.user_id FROM qvm_new_apps.user_data u
          WHERE u.user_type = 185 AND u.user_company = v_company_id
        LOOP
          IF NOT (v_recipient_id = ANY(v_dispatched_ids)) THEN
            PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
              jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id,
                'nav_target', v_internal_nav_target, 'order_number', v_order_number));
            v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
          END IF;
        END LOOP;
      END IF;
    END IF;

    IF 'webhook' = ANY(v_rule.channels) AND v_webhook_base_url IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_webhook_base_url,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object(
          'rule_id', v_rule.id,
          'trigger_status_id', p_new_status_id,
          'trigger_status_name', v_status_name,
          'recipient_type', v_rule.recipient_type,
          'message', v_message,
          'quotation_id', v_quotation_id,
          'quotation_item_id', p_quotation_item_id,
          'company_id', v_company_id
        )
      );
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.wa_note_quote_superseded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_order text;
  r       record;
  v_body  text;
BEGIN
  -- Set (for the current transaction only) by remove_item_from_purchase_order: the line went back
  -- to Confirmed because it came off its purchase order, not because anyone confirmed it.
  IF current_setting('qvm.status_back_from_po', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- Only on the transition into Confirmed.
  IF NEW.item_status IS DISTINCT FROM 19 OR OLD.item_status IS NOT DISTINCT FROM 19 THEN
    RETURN NEW;
  END IF;

  SELECT order_number INTO v_order
    FROM qvm_new_apps.quotations WHERE quotation_id = NEW.quotation_id;

  -- Every vendor who quoted this part but was not the one confirmed, and who
  -- has a conversation open with us.
  FOR r IN
    SELECT DISTINCT t.thread_id
      FROM qvm_new_apps.quotation_vendor_items vi
      JOIN qvm_new_apps.wa_contacts c ON c.vendor_id = vi.vendor_id
      JOIN qvm_new_apps.wa_threads  t ON t.wa_contact_id = c.wa_contact_id
     WHERE vi.quotation_item_id = NEW.quotation_item_id
       AND vi.cost > 0
       AND vi.best_cost IS DISTINCT FROM true
  LOOP
    v_body := 'تم شراء هذي القطعة من مورّد آخر على الطلب '
              || COALESCE(v_order, '#' || NEW.quotation_id)
              || ' — العرض المعلّق على "' || COALESCE(NEW.part_description, NEW.part_number, 'القطعة')
              || '" ما عاد مطلوب.';

    INSERT INTO qvm_new_apps.wa_messages (
      thread_id, direction, body, is_internal_note, is_system, wa_timestamp, delivery_status)
    VALUES (r.thread_id, 'out', v_body, true, true, now(), 'note');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- The inbox is a bystander here. A purchase must never fail because of it.
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_item_from_purchase_order(p_purchase_order_id bigint, p_confirmed_item_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_line record;
  v_item record;
  v_po record;
  v_other record;
  v_po_deleted boolean := false;
  v_status int;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.user_type = 185
  ) THEN
    RAISE EXCEPTION 'Only internal users can change a purchase order';
  END IF;

  SELECT po.purchase_order_id, po.vendor_invoice_url, po.vendor_invoice_number, po.zoho_bill_url, po.vendor_return_url
  INTO v_po
  FROM qvm_new_apps.purchase_orders po
  WHERE po.purchase_order_id = p_purchase_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Purchase order % does not exist', p_purchase_order_id;
  END IF;

  SELECT pi.purchase_item_id, pi.received_qty
  INTO v_line
  FROM qvm_new_apps.purchase_items pi
  WHERE pi.purchase_order_id = p_purchase_order_id AND pi.confirmed_item_id = p_confirmed_item_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This item is not on purchase order %', p_purchase_order_id;
  END IF;

  SELECT ci.confirmed_item_id, ci.quotation_item_id, qi.item_status, ld.list_data AS status_name
  INTO v_item
  FROM qvm_new_apps.confirmed_items ci
  JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
  WHERE ci.confirmed_item_id = p_confirmed_item_id
  FOR UPDATE OF ci, qi;

  -- Only a line still waiting on the vendor can come off. Once goods have moved, the purchase
  -- order is what they moved against.
  IF v_item.item_status IS NULL OR v_item.item_status NOT IN (19, 21) THEN
    RAISE EXCEPTION 'This item is % — only a Confirmed or Processing item can come off its purchase order', COALESCE(v_item.status_name, 'in another status');
  END IF;
  IF COALESCE(v_line.received_qty, 0) > 0 THEN
    RAISE EXCEPTION 'This item has already been received from the vendor';
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.delivery_items di WHERE di.confirmed_item_id = p_confirmed_item_id) THEN
    RAISE EXCEPTION 'This item is already on a delivery note';
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.pickup_items pk WHERE pk.purchase_item_id = v_line.purchase_item_id) THEN
    RAISE EXCEPTION 'This item already has a vendor pickup';
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.vendor_creditnote_items vc WHERE vc.purchase_item_id = v_line.purchase_item_id) THEN
    RAISE EXCEPTION 'This item is on a vendor credit note';
  END IF;

  DELETE FROM qvm_new_apps.purchase_items WHERE purchase_item_id = v_line.purchase_item_id;

  -- A purchase order left with no lines goes too, unless documents hang off it.
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_items pi WHERE pi.purchase_order_id = p_purchase_order_id)
     AND v_po.vendor_invoice_url IS NULL AND v_po.vendor_invoice_number IS NULL
     AND v_po.zoho_bill_url IS NULL AND v_po.vendor_return_url IS NULL
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.purchase_invoice_attachments a WHERE a.purchase_order_id = p_purchase_order_id)
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.pickups p WHERE p.purchase_order_id = p_purchase_order_id)
     AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_creditnotes v WHERE v.purchase_order_id = p_purchase_order_id)
  THEN
    DELETE FROM qvm_new_apps.purchase_orders WHERE purchase_order_id = p_purchase_order_id;
    v_po_deleted := true;
  END IF;

  -- Still bought on another vendor purchase order? Then it stays Processing, and its chosen price
  -- is that order's.
  SELECT pi.purchase_order_id, pi.cost_id
  INTO v_other
  FROM qvm_new_apps.purchase_items pi
  JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
  WHERE pi.confirmed_item_id = p_confirmed_item_id AND po.vendor_id IS NOT NULL
  ORDER BY po.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    v_status := v_item.item_status;
    IF v_other.cost_id IS NOT NULL THEN
      UPDATE qvm_new_apps.quotation_items
      SET cost_id = v_other.cost_id, updated_at = now()
      WHERE quotation_item_id = v_item.quotation_item_id AND cost_id IS DISTINCT FROM v_other.cost_id;
    END IF;
  ELSE
    -- Nothing bought any more: back to Confirmed, ready for a new purchase order. The chosen
    -- price is set when a purchase order is made, so it goes with it.
    v_status := 19;
    PERFORM set_config('qvm.status_back_from_po', 'on', true);
    UPDATE qvm_new_apps.confirmed_items
    SET item_status = 19, updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id AND item_status IS DISTINCT FROM 19;
    UPDATE qvm_new_apps.quotation_items
    SET item_status = 19, cost_id = NULL, updated_at = now()
    WHERE quotation_item_id = v_item.quotation_item_id;
    PERFORM set_config('qvm.status_back_from_po', '', true);

    IF v_item.item_status IS DISTINCT FROM 19 THEN
      INSERT INTO qvm_new_apps.status_logs (quotation_item_id, confirmed_item_id, item_status, status_changed_by)
      VALUES (v_item.quotation_item_id, p_confirmed_item_id, 19, v_uid);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Removed from purchase order',
    'purchase_order_id', p_purchase_order_id,
    'purchase_order_deleted', v_po_deleted,
    'item_status', v_status,
    'still_on_purchase_order', v_other.purchase_order_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.remove_item_from_purchase_order(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_item_from_purchase_order(bigint, integer) TO authenticated, service_role;

notify pgrst, 'reload schema';
