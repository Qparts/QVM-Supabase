-- A notification rule speaks English too.
--
-- The system has two languages; a rule had one wording. message_template_en carries the English
-- one, the existing rules get theirs here, the rule screen edits both, and the dispatcher fills
-- the English text the same way and sends it along as body_en in the notification's data, for a
-- reader whose app is in English. Webhooks receive message_en beside message.

set search_path to qvm_new_apps, public;

alter table qvm_new_apps.notification_rules add column if not exists message_template_en text;

update qvm_new_apps.notification_rules set message_template_en = 'Your quotation request #{order_id} has been received and is being prepared; we will send you the prices soon.' where id = 1 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'The quotation for your order #{order_id} is ready for review. Tap to see the prices: {link}' where id = 2 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your order #{order_id} has been confirmed; preparation is starting.' where id = 3 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your order #{order_id} is now being prepared.' where id = 4 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your order #{order_id} is out for delivery now.' where id = 5 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your order #{order_id} has been delivered. Please sign the delivery note: {link}' where id = 6 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Sorry, the item {part_name} in your order #{order_id} is currently unavailable; we are looking for an alternative.' where id = 7 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your cancellation request for order #{order_id} has been received and is under review.' where id = 8 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your order #{order_id} has been cancelled.' where id = 9 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your return request for order #{order_id} has been received.' where id = 10 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'The invoice for your order #{order_id} has been issued. Download it: {link}' where id = 11 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'A credit note has been issued for your order #{order_id}.' where id = 12 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'You have a new quotation request #{rfq_id} from QVM. Please price it before {deadline}.' where id = 13 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Your offer for request #{rfq_id} has been accepted. Please start preparing it.' where id = 14 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'Please prepare the item of order #{order_id} for delivery.' where id = 15 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'A claim has been raised on order #{order_id}. Details: {link}' where id = 16 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'A new quotation came back from a vendor for request #{rfq_id} and is waiting for your review.' where id = 17 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'A new cancellation request #{order_id} from customer {client_name} needs immediate review.' where id = 18 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'A new return request #{order_id} from customer {client_name} needs review.' where id = 19 and message_template_en is null;
update qvm_new_apps.notification_rules set message_template_en = 'The item {part_name} of order #{order_id} is unavailable at the vendor; an alternative is needed.' where id = 20 and message_template_en is null;
-- A rule whose Arabic wording is already English keeps it as its English wording too.
update qvm_new_apps.notification_rules set message_template_en = message_template where message_template_en is null and message_template !~ '[\u0600-\u06FF]';

-- The signatures gain a trailing optional parameter; the old ones go so the API has one of each.
drop function if exists qvm_new_apps.create_notification_rule(text, integer, text, integer, text, integer, text, text[]);
drop function if exists qvm_new_apps.update_notification_rule(bigint, text, integer, text, integer, text, integer, text, text[]);

CREATE OR REPLACE FUNCTION qvm_new_apps.create_notification_rule(p_trigger_type text, p_trigger_status_id integer, p_trigger_gate_key text, p_delay_hours integer, p_recipient_type text, p_recipient_role_id integer, p_message_template text, p_channels text[], p_message_template_en text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_trigger_type NOT IN ('status_change', 'gate_condition') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid trigger type');
  END IF;
  IF p_trigger_type = 'status_change' AND p_trigger_status_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A status is required for a status-change trigger');
  END IF;
  IF p_trigger_type = 'gate_condition' AND (p_trigger_gate_key IS NULL OR btrim(p_trigger_gate_key) = '') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A gate condition key is required');
  END IF;
  IF p_recipient_type NOT IN ('client', 'vendor', 'internal_role') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid recipient type');
  END IF;
  IF p_recipient_type = 'internal_role' AND p_recipient_role_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A role is required for an internal recipient');
  END IF;
  IF p_message_template IS NULL OR btrim(p_message_template) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Message template is required');
  END IF;

  INSERT INTO qvm_new_apps.notification_rules (
    trigger_type, trigger_status_id, trigger_gate_key, delay_hours,
    recipient_type, recipient_role_id, message_template, message_template_en, channels,
    created_by, updated_by
  ) VALUES (
    p_trigger_type, p_trigger_status_id, p_trigger_gate_key, COALESCE(p_delay_hours, 0),
    p_recipient_type, p_recipient_role_id, btrim(p_message_template), NULLIF(btrim(COALESCE(p_message_template_en, '')), ''),
    COALESCE(p_channels, ARRAY['browser_push']),
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_id;

  INSERT INTO qvm_new_apps.notification_rules_audit (rule_id, actor, action, old_value, new_value)
  VALUES (v_id, auth.uid(), 'create', NULL, to_jsonb((SELECT r FROM qvm_new_apps.notification_rules r WHERE r.id = v_id)));

  RETURN jsonb_build_object('status', 'success', 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.update_notification_rule(p_id bigint, p_trigger_type text, p_trigger_status_id integer, p_trigger_gate_key text, p_delay_hours integer, p_recipient_type text, p_recipient_role_id integer, p_message_template text, p_channels text[], p_message_template_en text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_old jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_trigger_type NOT IN ('status_change', 'gate_condition') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid trigger type');
  END IF;
  IF p_trigger_type = 'status_change' AND p_trigger_status_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A status is required for a status-change trigger');
  END IF;
  IF p_recipient_type NOT IN ('client', 'vendor', 'internal_role') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid recipient type');
  END IF;
  IF p_recipient_type = 'internal_role' AND p_recipient_role_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'A role is required for an internal recipient');
  END IF;
  IF p_message_template IS NULL OR btrim(p_message_template) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Message template is required');
  END IF;

  SELECT to_jsonb(r) INTO v_old FROM qvm_new_apps.notification_rules r WHERE r.id = p_id;
  IF v_old IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Rule not found');
  END IF;

  UPDATE qvm_new_apps.notification_rules SET
    trigger_type = p_trigger_type,
    trigger_status_id = p_trigger_status_id,
    trigger_gate_key = p_trigger_gate_key,
    delay_hours = COALESCE(p_delay_hours, 0),
    recipient_type = p_recipient_type,
    recipient_role_id = p_recipient_role_id,
    message_template = btrim(p_message_template),
    message_template_en = NULLIF(btrim(COALESCE(p_message_template_en, '')), ''),
    channels = COALESCE(p_channels, ARRAY['browser_push']),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = p_id;

  INSERT INTO qvm_new_apps.notification_rules_audit (rule_id, actor, action, old_value, new_value)
  VALUES (p_id, auth.uid(), 'update', v_old, to_jsonb((SELECT r FROM qvm_new_apps.notification_rules r WHERE r.id = p_id)));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_notification_rules()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', r.id,
           'trigger_type', r.trigger_type,
           'trigger_status_id', r.trigger_status_id,
           'trigger_status_name', ts.list_data,
           'trigger_gate_key', r.trigger_gate_key,
           'delay_hours', r.delay_hours,
           'recipient_type', r.recipient_type,
           'recipient_role_id', r.recipient_role_id,
           'recipient_role_name', rr.list_data,
           'message_template', r.message_template,
           'message_template_en', r.message_template_en,
           'channels', r.channels,
           'is_active', r.is_active,
           'created_at', r.created_at,
           'updated_at', r.updated_at
         ) ORDER BY r.trigger_status_id NULLS LAST, r.id), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.notification_rules r
  LEFT JOIN qvm_new_apps.list_data ts ON ts.list_data_id = r.trigger_status_id
  LEFT JOIN qvm_new_apps.list_data rr ON rr.list_data_id = r.recipient_role_id;

  RETURN v_result;
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
  v_message_en text;
  v_recipient_id uuid;
  v_dispatched_ids uuid[];
  -- 'Priced' (17) on a not-yet-confirmed item is specifically "vendor pricing needs review on the
  -- comparison page" — an internal-only workflow step, hence only applied to internal recipients.
  v_internal_nav_target text;
  v_client_nav_target text;
BEGIN
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
    -- The English wording, filled the same way. It rides in the notification's data as body_en;
    -- the app shows it to a reader whose language is English and falls back to the Arabic body.
    v_message_en := v_rule.message_template_en;
    IF v_message_en IS NOT NULL THEN
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
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
              'nav_target', v_client_nav_target, 'order_number', v_order_number));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      ELSIF v_rule.recipient_type = 'vendor' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_vendor_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id, 'body_en', v_message_en,
              'nav_target', 'vendor-quotation', 'order_number', v_order_number));
        END LOOP;
      ELSIF v_rule.recipient_type = 'internal_role' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_internal_role_recipients(v_rule.recipient_role_id, v_account_manager) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
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
            PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
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
