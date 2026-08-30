-- Clicking a notification in the header bell should navigate to the actual record it's about
-- (an RFQ, a confirmed order, a vendor's own quotation view) instead of doing nothing. Neither
-- existing push-dispatch path (dispatch_notification_rules from QNEW-99, dispatch_record_activity_push
-- from QNEW-100) ever included a navigable target in its push data — dispatch_notification_rules
-- carried quotation_id but no route, and dispatch_record_activity_push carried only activity_id, not
-- even quotation_id. This adds a `nav_target` + `order_number` pair to every push data payload; the
-- frontend (components/layout/Header.tsx) builds the actual URL from those two fields rather than a
-- server-built path, so it can apply the same encodeURIComponent(orderNumber) convention already used
-- by every other deep link in this app (OrdersDashboardPage's `?open=`, PricingPage's `?order_number=`).
--
-- nav_target values and what they mean to the frontend:
--   'pricing'          -> /pricing?order_number=<order_number>   (Compare & Price / vendor pricing review)
--   'orders'           -> /orders?open=<order_number>             (post-confirmation order stage)
--   'rfqs'             -> /rfqs?open=<order_number>                (pre-confirmation RFQ stage)
--   'vendor-quotation' -> /vendor-dashboard/quotations/<quotation_id> (vendor's own portal, no order_number route there)
--
-- 'pricing' is only used for internal recipients (account manager / internal company staff) —
-- clients and vendors don't have a comparison page, so client-type notifications route to
-- 'rfqs'/'orders' like everything else, and vendor-type notifications get their own
-- 'vendor-quotation' target instead of the internal-only rfqs/orders/pricing pages.

DROP FUNCTION IF EXISTS qvm_new_apps.dispatch_notification_rules(integer, integer);

CREATE FUNCTION qvm_new_apps.dispatch_notification_rules(p_quotation_item_id integer, p_new_status_id integer, p_source_table text DEFAULT 'quotation_items')
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

REVOKE ALL ON FUNCTION qvm_new_apps.dispatch_notification_rules(integer, integer, text) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_qi()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  BEGIN
    PERFORM qvm_new_apps.dispatch_notification_rules(NEW.quotation_item_id, NEW.item_status, 'quotation_items');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    PERFORM qvm_new_apps.log_activity(NEW.quotation_id, 'quotation_items', 'status_change',
      jsonb_build_object('item_status', OLD.item_status), jsonb_build_object('item_status', NEW.item_status),
      NEW.quotation_item_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_ci()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation_id integer;
BEGIN
  BEGIN
    PERFORM qvm_new_apps.dispatch_notification_rules(NEW.quotation_item_id, NEW.item_status, 'confirmed_items');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    SELECT quotation_id INTO v_quotation_id FROM qvm_new_apps.quotation_items WHERE quotation_item_id = NEW.quotation_item_id;
    IF v_quotation_id IS NOT NULL THEN
      PERFORM qvm_new_apps.log_activity(v_quotation_id, 'confirmed_items', 'status_change',
        jsonb_build_object('item_status', OLD.item_status), jsonb_build_object('item_status', NEW.item_status),
        NEW.quotation_item_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

-- QNEW-100's push path never carried quotation_id at all (only activity_id) and therefore couldn't
-- support either "mark viewed on click" or "navigate to entity" — activity_log rows are always
-- internal-only recipients (log_activity's owner/CC resolution never includes clients or vendors),
-- so nav_target here only ever needs the internal 'pricing'/'rfqs'/'orders' values, same mapping
-- get_unseen_activity_summary() already uses to bucket source_table into the RFQs/Orders sidebar counts.
CREATE OR REPLACE FUNCTION qvm_new_apps.dispatch_record_activity_push(p_activity_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_owner uuid;
  v_summary text;
  v_record_id bigint;
  v_source_table text;
  v_quotation_item_id bigint;
  v_order_number text;
  v_nav_target text;
  v_enabled boolean;
BEGIN
  SELECT owner_user_id, summary, record_id, source_table, quotation_item_id
  INTO v_owner, v_summary, v_record_id, v_source_table, v_quotation_item_id
  FROM qvm_new_apps.activity_log WHERE id = p_activity_id;

  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = v_record_id;

  v_nav_target := CASE
    WHEN v_source_table = 'confirmed_items' THEN 'orders'
    WHEN v_source_table = 'quotation_vendor_items' THEN 'pricing'
    ELSE 'rfqs'
  END;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.notification_rules
    WHERE trigger_type = 'record_activity' AND is_active AND 'browser_push' = ANY(channels)
  ) INTO v_enabled;

  IF v_enabled THEN
    PERFORM qvm_new_apps.dispatch_push_to_user(v_owner, 'QVM', v_summary,
      jsonb_build_object('activity_id', p_activity_id, 'quotation_id', v_record_id,
        'quotation_item_id', v_quotation_item_id, 'nav_target', v_nav_target, 'order_number', v_order_number));
  END IF;
END;
$function$;
