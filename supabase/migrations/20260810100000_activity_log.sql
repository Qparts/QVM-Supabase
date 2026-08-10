-- QNEW-100 Phase 1: a scoped activity log for "unseen activity" badges — NOT the aspirational
-- system-wide audit_log the ticket describes (no such table, or the "Phase-1 plan" that supposedly
-- specified it, exists anywhere in this repo). This instruments only the specific tables Phase 1
-- needs: order-owner (quotations.account_manager) activity from status changes, vendor additions,
-- and price changes. record_type is 'order' now; 'vendor_quote' (vendor-company ownership) is a
-- reserved, not-yet-used value for the Phase 2 fast-follow.
CREATE TABLE qvm_new_apps.activity_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  record_type text NOT NULL,
  record_id bigint NOT NULL,
  -- The specific item this activity is about, when there is one (price changes, item status
  -- changes) — NULL for order/vendor-level activity (e.g. vendor_added). Lets counts distinguish
  -- "3 items were priced" from "this one item was priced 3 times".
  quotation_item_id bigint NULL,
  source_table text NOT NULL,
  owner_user_id uuid NOT NULL,
  action text NOT NULL,
  actor_user_id uuid,
  summary text,
  old_values jsonb,
  new_values jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_activity_log_record ON qvm_new_apps.activity_log (record_type, record_id);
CREATE INDEX idx_activity_log_owner ON qvm_new_apps.activity_log (owner_user_id, created_at);

ALTER TABLE qvm_new_apps.activity_log ENABLE ROW LEVEL SECURITY;

-- Enforced at the data layer per QNEW-100's acceptance criteria, not just hidden in the UI.
CREATE POLICY activity_log_select ON qvm_new_apps.activity_log
  FOR SELECT USING (owner_user_id = auth.uid());

CREATE TABLE qvm_new_apps.record_views (
  user_id uuid NOT NULL,
  record_type text NOT NULL,
  record_id bigint NOT NULL,
  last_viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, record_type, record_id)
);

ALTER TABLE qvm_new_apps.record_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY record_views_own ON qvm_new_apps.record_views
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Resolves the order's owner (quotations.account_manager, same column QNEW-99's
-- resolve_internal_role_recipients already treats as "record owner"), PLUS every internal staff
-- member (user_type=185) tagged to the order's own client company via user_data.user_company —
-- the same company_id space (list_id=1) used for notification_settings — so a whole team assigned
-- to an account sees the badge, not just the one person in the account_manager column. One
-- activity_log row per recipient (each gets their own independent seen/unseen state via
-- record_views, keyed by user_id), deduped, excluding the actor themselves and the order having no
-- resolvable recipient at all.
CREATE FUNCTION qvm_new_apps.log_activity(
  p_quotation_id integer,
  p_source_table text,
  p_action text,
  p_old jsonb,
  p_new jsonb,
  p_quotation_item_id bigint DEFAULT NULL
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_account_manager uuid;
  v_order_number text;
  v_company_id integer;
  v_summary text;
  v_recipient uuid;
  v_activity_id bigint;
BEGIN
  SELECT account_manager, order_number INTO v_account_manager, v_order_number
  FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;

  SELECT cb.list_data_id INTO v_company_id
  FROM qvm_new_apps.quotation_items qi
  JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
  WHERE qi.quotation_id = p_quotation_id
  LIMIT 1;

  v_summary := CASE p_action
    WHEN 'status_change' THEN 'Order #' || COALESCE(v_order_number, p_quotation_id::text) || ' status changed'
    WHEN 'vendor_added' THEN 'A vendor was added to order #' || COALESCE(v_order_number, p_quotation_id::text)
    WHEN 'price_added' THEN 'A price was added on order #' || COALESCE(v_order_number, p_quotation_id::text)
    WHEN 'price_edited' THEN 'A price was edited on order #' || COALESCE(v_order_number, p_quotation_id::text)
    ELSE 'Activity on order #' || COALESCE(v_order_number, p_quotation_id::text)
  END;

  FOR v_recipient IN
    SELECT DISTINCT uid FROM (
      SELECT v_account_manager AS uid
      UNION
      SELECT u.user_id FROM qvm_new_apps.user_data u
      WHERE v_company_id IS NOT NULL AND u.user_type = 185 AND u.user_company = v_company_id
    ) recipients
    WHERE uid IS NOT NULL AND (auth.uid() IS NULL OR uid <> auth.uid())
  LOOP
    INSERT INTO qvm_new_apps.activity_log (
      record_type, record_id, quotation_item_id, source_table, owner_user_id, action, actor_user_id, summary, old_values, new_values
    ) VALUES (
      'order', p_quotation_id, p_quotation_item_id, p_source_table, v_recipient, p_action, auth.uid(), v_summary, p_old, p_new
    ) RETURNING id INTO v_activity_id;

    PERFORM qvm_new_apps.dispatch_record_activity_push(v_activity_id);
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.log_activity(integer, text, text, jsonb, jsonb, bigint) FROM public, anon, authenticated;

-- Away-from-app delivery, reusing QNEW-99's dispatch_push_to_user primitive — no second mechanism.
-- Gated on a single admin-toggleable notification_rules row (trigger_type = 'record_activity'):
-- if it's missing, disabled, or doesn't have browser_push enabled, this is a silent no-op (the
-- in-app badge itself is unaffected either way, since it reads activity_log directly).
CREATE FUNCTION qvm_new_apps.dispatch_record_activity_push(p_activity_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_owner uuid;
  v_summary text;
  v_enabled boolean;
BEGIN
  SELECT owner_user_id, summary INTO v_owner, v_summary
  FROM qvm_new_apps.activity_log WHERE id = p_activity_id;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.notification_rules
    WHERE trigger_type = 'record_activity' AND is_active AND 'browser_push' = ANY(channels)
  ) INTO v_enabled;

  IF v_enabled THEN
    PERFORM qvm_new_apps.dispatch_push_to_user(v_owner, 'QVM', v_summary, jsonb_build_object('activity_id', p_activity_id));
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.dispatch_record_activity_push(bigint) FROM public, anon, authenticated;

-- Extend QNEW-99's existing status-change triggers with this one more side effect — no new trigger
-- needed on quotation_items/confirmed_items.
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_dispatch_notification_rules_qi()
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
    PERFORM qvm_new_apps.dispatch_notification_rules(NEW.quotation_item_id, NEW.item_status);
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

-- New trigger: a vendor was added to an order (create_vendors_quotations inserting into
-- quotation_vendors) — fires once per vendor added.
CREATE FUNCTION qvm_new_apps.trg_log_activity_vendor_added()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  BEGIN
    PERFORM qvm_new_apps.log_activity(NEW.quotation_id, 'quotation_vendors', 'vendor_added',
      NULL, jsonb_build_object('vendor_id', NEW.vendor_id, 'vendor_branch_id', NEW.vendor_branch_id));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_log_activity_vendor_added
  AFTER INSERT ON qvm_new_apps.quotation_vendors
  FOR EACH ROW
  EXECUTE FUNCTION qvm_new_apps.trg_log_activity_vendor_added();

-- New trigger: a vendor priced (or re-priced) an item on the order — fires on the first real price
-- (INSERT with a non-null cost, or an UPDATE that sets/changes a non-null cost).
CREATE FUNCTION qvm_new_apps.trg_log_activity_vendor_price()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation_id integer;
  v_action text;
BEGIN
  -- 0 means "no real price yet", same as NULL — SendVendorRFQModal.tsx creates every
  -- quotation_vendor_items row with cost=0 as a placeholder the instant an RFQ is sent to a
  -- vendor, before the vendor has priced anything. Without this check that placeholder insert was
  -- misread as the vendor's first price.
  IF NEW.cost IS NULL OR NEW.cost <= 0 THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.cost IS NOT DISTINCT FROM NEW.cost THEN
    RETURN NEW;
  END IF;
  v_action := CASE WHEN TG_OP = 'INSERT' OR OLD.cost IS NULL OR OLD.cost <= 0 THEN 'price_added' ELSE 'price_edited' END;

  BEGIN
    SELECT qv.quotation_id INTO v_quotation_id
    FROM qvm_new_apps.quotation_vendors qv WHERE qv.quotation_vendor_id = NEW.quotation_vendor_id;
    IF v_quotation_id IS NOT NULL THEN
      PERFORM qvm_new_apps.log_activity(v_quotation_id, 'quotation_vendor_items', v_action,
        jsonb_build_object('cost', CASE WHEN TG_OP = 'UPDATE' THEN OLD.cost ELSE NULL END),
        jsonb_build_object('cost', NEW.cost),
        NEW.quotation_item_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_log_activity_vendor_price
  AFTER INSERT OR UPDATE ON qvm_new_apps.quotation_vendor_items
  FOR EACH ROW
  EXECUTE FUNCTION qvm_new_apps.trg_log_activity_vendor_price();
