-- The invoice upload says the invoice was uploaded, not that the order was delivered.
--
-- Filing a supplier's invoice on the purchase orders page moves the order's lines along — what
-- is still with the supplier to Out for Delivery, what the client already has to Settled — and
-- the status rules spoke for those moves: «Your order has been delivered. Please sign the
-- delivery note», sent for an upload. Now the upload is one server call that marks the change as
-- a document landing, and the dispatcher, seeing that mark, sends the document's own rule —
-- «Purchase invoice for order #X has been uploaded successfully» — in place of the status rules.

-- The rule. Its trigger is the document, not a status; the Notification Rules page edits its
-- wording like any other rule's.
INSERT INTO qvm_new_apps.notification_rules
  (trigger_type, trigger_status_id, trigger_gate_key, delay_hours, recipient_type, recipient_role_id,
   message_template, message_template_en, channels, is_active)
SELECT 'document_uploaded', NULL, 'purchase_invoice', 0, 'client', NULL,
       'تم رفع {purchase_invoice_type} للطلب #{order_id} بنجاح',
       '{purchase_invoice_type} for order #{order_id} has been uploaded successfully',
       ARRAY['browser_push', 'email', 'whatsapp'], true
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.notification_rules
                   WHERE trigger_type = 'document_uploaded' AND trigger_gate_key = 'purchase_invoice');

-- The upload's status moves, in one call that carries the mark. The forward-only step is the one
-- the page used to make from the browser: a line not yet out for delivery goes to Out for Delivery,
-- a line that is further along is left where it is; then the delivered lines settle.
CREATE OR REPLACE FUNCTION qvm_new_apps.record_purchase_invoice_upload(p_quotation_item_ids integer[], p_document_type text DEFAULT 'purchase_invoice')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_moved integer := 0;
  v_settled jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Internal users only');
  END IF;
  IF p_quotation_item_ids IS NULL OR array_length(p_quotation_item_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('moved', 0, 'settled', 0));
  END IF;

  -- For this transaction only: every status change below is a document landing.
  PERFORM set_config('qvm.notification_context', 'document_uploaded:' || COALESCE(NULLIF(btrim(p_document_type), ''), 'purchase_invoice'), true);

  WITH ranked AS (
    SELECT qi.quotation_item_id,
           CASE qi.item_status WHEN 236 THEN 1 WHEN 235 THEN 2 WHEN 237 THEN 3 WHEN 17 THEN 4 WHEN 19 THEN 5
                               WHEN 21 THEN 6 WHEN 22 THEN 7 WHEN 23 THEN 8 WHEN 31 THEN 9 ELSE qi.item_status END AS rank
      FROM qvm_new_apps.quotation_items qi
     WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
  ),
  moved AS (
    UPDATE qvm_new_apps.quotation_items qi
       SET item_status = 22, updated_at = now()
      FROM ranked r
     WHERE r.quotation_item_id = qi.quotation_item_id
       AND (r.rank IS NULL OR r.rank < 7)
    RETURNING 1
  )
  SELECT count(*) INTO v_moved FROM moved;

  v_settled := qvm_new_apps.settle_delivered_items(p_quotation_item_ids);

  -- The mark is this call's alone: whatever else runs in the same transaction speaks for itself.
  PERFORM set_config('qvm.notification_context', '', true);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'moved', v_moved,
    'settled', COALESCE((v_settled -> 'data' ->> 'settled')::int, 0)));
END $function$;

CREATE OR REPLACE FUNCTION public.record_purchase_invoice_upload(p_quotation_item_ids integer[], p_document_type text DEFAULT 'purchase_invoice')
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.record_purchase_invoice_upload(p_quotation_item_ids, p_document_type) $function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.record_purchase_invoice_upload(integer[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_purchase_invoice_upload(integer[], text) TO authenticated;

-- The dispatcher: the document's rule when the change is a document landing, the status's otherwise.
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
  v_message_en text;
  v_recipient_id uuid;
  v_dispatched_ids uuid[];
  -- 'Priced' (17) on a not-yet-confirmed item is specifically "vendor pricing needs review on the
  -- comparison page" — an internal-only workflow step, hence only applied to internal recipients.
  v_internal_nav_target text;
  v_client_nav_target text;
  -- Set by the write that caused the change when it is a document landing, not a step in the
  -- delivery: 'document_uploaded:<key>'. Then the document's own rule speaks, not the status's.
  v_context text := current_setting('qvm.notification_context', true);
  v_doc_key text;
  v_doc_name_ar text;
  v_doc_name_en text;
  v_title text;
BEGIN
  IF v_context LIKE 'document_uploaded:%' THEN
    v_doc_key := split_part(v_context, ':', 2);
    v_doc_name_ar := CASE v_doc_key WHEN 'purchase_invoice' THEN 'فاتورة الشراء' WHEN 'vendor_creditnote' THEN 'إشعار الدائن' ELSE v_doc_key END;
    v_doc_name_en := CASE v_doc_key WHEN 'purchase_invoice' THEN 'Purchase invoice' WHEN 'vendor_creditnote' THEN 'Credit note' ELSE v_doc_key END;
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

  v_title := COALESCE(CASE WHEN v_doc_key IS NOT NULL THEN v_doc_name_en END, v_status_name, 'QVM');

  FOR v_rule IN
    SELECT * FROM qvm_new_apps.notification_rules
    WHERE delay_hours = 0
      AND is_active
      AND (
        (v_doc_key IS NULL AND trigger_type = 'status_change' AND trigger_status_id = p_new_status_id)
        OR (v_doc_key IS NOT NULL AND trigger_type = 'document_uploaded' AND trigger_gate_key = v_doc_key)
      )
  LOOP
    v_message := v_rule.message_template;
    v_message := replace(v_message, '{purchase_invoice_type}', COALESCE(v_doc_name_ar, ''));
    v_message := replace(v_message, '{order_id}', COALESCE(v_order_number, ''));
    v_message := replace(v_message, '{rfq_id}', COALESCE(v_order_number, ''));
    v_message := replace(v_message, '{client_name}', COALESCE(v_client_name, ''));
    v_message := replace(v_message, '{part_name}', COALESCE(v_part_name, ''));
    v_message := replace(v_message, '{link}', '');
    v_message := replace(v_message, '{deadline}', '');
    -- The English wording, filled the same way. It rides in the notification's data as body_en;
    -- the app shows it to a reader whose language is English and falls back to the Arabic body.
    v_message_en := v_rule.message_template_en;
    IF v_message_en IS NOT NULL THEN
      v_message_en := replace(v_message_en, '{purchase_invoice_type}', COALESCE(v_doc_name_en, ''));
      v_message_en := replace(v_message_en, '{order_id}', COALESCE(v_order_number, ''));
      v_message_en := replace(v_message_en, '{rfq_id}', COALESCE(v_order_number, ''));
      v_message_en := replace(v_message_en, '{client_name}', COALESCE(v_client_name, ''));
      v_message_en := replace(v_message_en, '{part_name}', COALESCE(v_part_name, ''));
      v_message_en := replace(v_message_en, '{link}', '');
      v_message_en := replace(v_message_en, '{deadline}', '');
    END IF;

    IF 'browser_push' = ANY(v_rule.channels) THEN
      v_dispatched_ids := ARRAY[]::uuid[];
      IF v_rule.recipient_type = 'client' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_client_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, v_title, v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
              'nav_target', v_client_nav_target, 'order_number', v_order_number));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      ELSIF v_rule.recipient_type = 'vendor' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_vendor_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, v_title, v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
              'nav_target', 'vendor-quotation', 'order_number', v_order_number));
        END LOOP;
      ELSIF v_rule.recipient_type = 'internal_role' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_internal_role_recipients(v_rule.recipient_role_id, v_account_manager) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, v_title, v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
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
            PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, v_title, v_message,
              jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
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
          'document_type', v_doc_key,
          'trigger_status_id', p_new_status_id,
          'trigger_status_name', v_status_name,
          'recipient_type', v_rule.recipient_type,
          'message', v_message,
          'message_en', v_message_en,
          'quotation_id', v_quotation_id,
          'quotation_item_id', p_quotation_item_id,
          'company_id', v_company_id
        )
      );
    END IF;
  END LOOP;
END;
$function$;
