-- QNEW-99 Phase 1 dispatch mechanism.
--
-- 1) send_notification_to_user (20260804120000_fcm_push_notifications.sql) enforces "target must
--    be in caller's own company" — correct for the ad-hoc admin composer (SendNotificationPage,
--    peer-to-company broadcast), wrong here: an internal status change must be able to push to a
--    *different* company's user (the client or the vendor on that record). Extract the actual
--    insert-notification + enqueue-deliveries + net.http_post work into a lower-level primitive
--    with no company check, and have send_notification_to_user call it after its own guard.
CREATE FUNCTION qvm_new_apps.dispatch_push_to_user(p_user_id uuid, p_title text, p_body text, p_data jsonb DEFAULT NULL::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_notification_id bigint;
BEGIN
  INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
  VALUES (btrim(p_title), btrim(p_body), p_data, 'user', p_user_id, auth.uid())
  RETURNING id INTO v_notification_id;

  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  VALUES (v_notification_id, p_user_id);

  INSERT INTO qvm_new_apps.notification_deliveries (notification_id, device_token_id, status)
  SELECT v_notification_id, dt.id, 'pending'
  FROM qvm_new_apps.device_tokens dt
  WHERE dt.user_id = p_user_id AND dt.is_active;

  PERFORM net.http_post(
    url := 'https://exizrhlkxoqljiypzwyx.supabase.co/functions/v1/send-push-notification',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('notification_id', v_notification_id)
  );

  RETURN v_notification_id;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.dispatch_push_to_user(uuid, text, text, jsonb) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION qvm_new_apps.send_notification_to_user(p_user_id uuid, p_title text, p_body text, p_data jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_sender_company_id integer;
  v_target_company_id integer;
  v_notification_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_title IS NULL OR btrim(p_title) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Title and body are required');
  END IF;
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Target user is required');
  END IF;

  SELECT user_company INTO v_sender_company_id FROM qvm_new_apps.user_data WHERE user_id = auth.uid();
  SELECT user_company INTO v_target_company_id FROM qvm_new_apps.user_data WHERE user_id = p_user_id;

  IF v_sender_company_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Your account has no associated client — contact an administrator');
  END IF;
  IF v_target_company_id IS NULL OR v_target_company_id != v_sender_company_id THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Target user is not in your company');
  END IF;

  v_notification_id := qvm_new_apps.dispatch_push_to_user(p_user_id, p_title, p_body, p_data);

  RETURN jsonb_build_object('status', 'success', 'id', v_notification_id);
END;
$function$;

-- 2) Recipient resolution, one function per recipient_type.
-- user_branch is NOT exclusive to client-type users (it's also set on internal/vendor rows for
-- unrelated branch-scoped filtering elsewhere in the app) — must also filter user_type = 183
-- ('Clients', per the user_type list_data catalog), confirmed live on QVM/dev before this was
-- caught: without it, an internal staff member or a vendor sharing the same branch id would
-- wrongly receive a "client" notification.
CREATE FUNCTION qvm_new_apps.resolve_client_recipients(p_quotation_item_id integer)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT DISTINCT u.user_id
  FROM qvm_new_apps.quotation_items qi
  JOIN qvm_new_apps.user_data u ON u.user_branch = qi.customer_id AND u.user_type = 183
  WHERE qi.quotation_item_id = p_quotation_item_id;
$function$;

-- An item is often sent to SEVERAL vendors for competing quotes (quotation_vendor_items has one
-- row per vendor per item) — there is no reliable "winning vendor" flag once confirmed
-- (quotation_vendor_items.best_cost was checked live on QVM/dev and found essentially unpopulated
-- on real confirmed items), so Phase 1 notifies every vendor linked to the item rather than
-- guessing one. This is exactly correct for "Sent To Vendor" (every recipient of the RFQ) and a
-- documented simplification for later-stage vendor rows (Confirmed/Processing/Claim Sent may
-- notify more than just the selected vendor) — to be tightened once a definitive "selected vendor"
-- signal is confirmed.
CREATE FUNCTION qvm_new_apps.resolve_vendor_recipients(p_quotation_item_id integer)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  WITH v AS (
    SELECT DISTINCT qv.vendor_id, qv.vendor_branch_id
    FROM qvm_new_apps.quotation_vendor_items qvi
    JOIN qvm_new_apps.quotation_vendors qv ON qv.quotation_vendor_id = qvi.quotation_vendor_id
    WHERE qvi.quotation_item_id = p_quotation_item_id
  )
  SELECT DISTINCT u.user_id
  FROM v
  JOIN qvm_new_apps.user_data u ON u.user_vendor = v.vendor_id
  JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
  WHERE ur.list_data = 'Vendor Admin'
  UNION
  SELECT DISTINCT u.user_id
  FROM v
  JOIN qvm_new_apps.user_data u ON u.user_vendor = v.vendor_id
  WHERE v.vendor_branch_id IS NULL
     OR EXISTS (
       SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
       WHERE vbu.user_id = u.user_id AND vbu.vendor_branch_id = v.vendor_branch_id
     );
$function$;

-- "Account Manager (record owner)" in the ticket's seed data means the specific user already
-- assigned to this record (quotations.account_manager), not a broadcast to every Account Manager —
-- every other internal_role recipient broadcasts to all users holding that role.
CREATE FUNCTION qvm_new_apps.resolve_internal_role_recipients(p_recipient_role_id integer, p_account_manager uuid)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_role_name text;
BEGIN
  SELECT list_data INTO v_role_name FROM qvm_new_apps.list_data WHERE list_data_id = p_recipient_role_id;

  IF v_role_name = 'Qparts Account Manager' THEN
    IF p_account_manager IS NOT NULL THEN
      RETURN QUERY SELECT p_account_manager;
    END IF;
    RETURN;
  END IF;

  RETURN QUERY
    SELECT u.user_id FROM qvm_new_apps.user_data u
    WHERE u.user_role = p_recipient_role_id AND u.user_type = 185;
END;
$function$;

-- 3) Match active immediate rules for a status transition, render the message, dispatch push
--    and/or webhook. Called from the AFTER UPDATE triggers below — one call per item-status
--    transition, so no dedup/log table is needed (unlike the deferred delay_hours/gate_condition
--    rules, which need periodic re-evaluation and therefore dedup tracking).
CREATE FUNCTION qvm_new_apps.dispatch_notification_rules(p_quotation_item_id integer, p_new_status_id integer)
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
BEGIN
  -- v_company_id is the owning client company (client_branches.list_data_id, the same list_id=1
  -- space as get_clients_rows()/insurance_companies.client_id) — notification_settings is
  -- configured per company, not system-wide, so every dispatch for this quotation (client, vendor,
  -- or internal recipient) uses that company's own webhook configuration.
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
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      ELSIF v_rule.recipient_type = 'vendor' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_vendor_recipients(p_quotation_item_id) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id));
        END LOOP;
      ELSIF v_rule.recipient_type = 'internal_role' THEN
        FOR v_recipient_id IN SELECT * FROM qvm_new_apps.resolve_internal_role_recipients(v_rule.recipient_role_id, v_account_manager) LOOP
          PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
            jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id));
          v_dispatched_ids := array_append(v_dispatched_ids, v_recipient_id);
        END LOOP;
      END IF;

      -- Keep the internal team assigned to this client account (user_data.user_company, same
      -- company_id space as notification_settings) in the loop on every notification EXCEPT ones
      -- addressed to a vendor — those are operational instructions to the vendor, not client/order
      -- updates the account team needs cc'd on. Deduped against whoever the rule already notified.
      IF v_rule.recipient_type != 'vendor' AND v_company_id IS NOT NULL THEN
        FOR v_recipient_id IN
          SELECT u.user_id FROM qvm_new_apps.user_data u
          WHERE u.user_type = 185 AND u.user_company = v_company_id
        LOOP
          IF NOT (v_recipient_id = ANY(v_dispatched_ids)) THEN
            PERFORM qvm_new_apps.dispatch_push_to_user(v_recipient_id, COALESCE(v_status_name, 'QVM'), v_message,
              jsonb_build_object('quotation_id', v_quotation_id, 'quotation_item_id', p_quotation_item_id, 'rule_id', v_rule.id));
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

REVOKE ALL ON FUNCTION qvm_new_apps.dispatch_notification_rules(integer, integer) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION qvm_new_apps.resolve_client_recipients(integer) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION qvm_new_apps.resolve_vendor_recipients(integer) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION qvm_new_apps.resolve_internal_role_recipients(integer, uuid) FROM public, anon, authenticated;

-- 4) Triggers — one shared function, mirroring the proven trg_update_item_status_in_sheet shape
--    (20260709125803), fired on both quotation_items and confirmed_items so every status-changing
--    RPC (change_item_status_bulk, create_vendors_quotations, PO creation, delivery/return-note
--    signing, invoice issuance) is covered without touching any of them individually.
-- Dispatch failures (missing auth context on a service-role-driven update, a transient net.http_post
-- error, etc.) must never roll back the real status change — swallow and move on.
CREATE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_qi()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  BEGIN
    PERFORM qvm_new_apps.dispatch_notification_rules(NEW.quotation_item_id, NEW.item_status);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_dispatch_notification_rules_qi ON qvm_new_apps.quotation_items;

CREATE TRIGGER trg_dispatch_notification_rules_qi
  AFTER UPDATE ON qvm_new_apps.quotation_items
  FOR EACH ROW
  WHEN (NEW.item_status IS DISTINCT FROM OLD.item_status)
  EXECUTE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_qi();

CREATE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_ci()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  BEGIN
    PERFORM qvm_new_apps.dispatch_notification_rules(NEW.quotation_item_id, NEW.item_status);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_dispatch_notification_rules_ci ON qvm_new_apps.confirmed_items;

CREATE TRIGGER trg_dispatch_notification_rules_ci
  AFTER UPDATE ON qvm_new_apps.confirmed_items
  FOR EACH ROW
  WHEN (NEW.item_status IS DISTINCT FROM OLD.item_status)
  EXECUTE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_ci();
