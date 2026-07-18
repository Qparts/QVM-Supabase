-- Synced from QVM/test branch applied migration history (version 20260717210659, name: qnew_vendor_added_items_approval_workflow)

-- QNEW: vendors can suggest new items on a quotation; admin approves/rejects before distribution.

-- 1) New item statuses (list_id = 3). Idempotent.
INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 3, 'Added by Vendor'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor');

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 3, 'Cancelled'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Cancelled');

-- 2) created_by on quotation_items (QNEW-6 dependency).
ALTER TABLE qvm_new_apps.quotation_items
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id);

-- 3) Vendor adds a new item to a quotation (from the logged-in vendor portal).
CREATE OR REPLACE FUNCTION public.add_quotation_item_by_vendor(
  p_quotation_id int,
  p_part_number text DEFAULT NULL,
  p_part_description text DEFAULT NULL,
  p_quantity int DEFAULT 1,
  p_brand_class int DEFAULT NULL,
  p_cost numeric DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_vendor bigint;
  v_utype text;
  v_qv_id bigint;
  v_status_added int;
  v_order_number text;
  v_next_index int;
  v_line_item_code text;
  v_item_id bigint;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Not authenticated');
  END IF;

  SELECT ud.user_vendor, ud.user_type::text INTO v_vendor, v_utype
  FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_user;
  IF v_vendor IS NULL OR v_utype <> '205' THEN
    RETURN jsonb_build_object('status','error','message','Only vendor users can add items');
  END IF;

  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;
  IF v_order_number IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Invalid quotation_id');
  END IF;

  -- vendor must be attached to this quotation (get or create their quotation_vendors row)
  SELECT quotation_vendor_id INTO v_qv_id
  FROM qvm_new_apps.quotation_vendors
  WHERE quotation_id = p_quotation_id AND vendor_id = v_vendor LIMIT 1;
  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
    VALUES (v_vendor, p_quotation_id, now()) RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  SELECT list_data_id INTO v_status_added
  FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(line_item_code,''),'^.*-([0-9]+)$','\1'),'')::int),0) + 1
  INTO v_next_index FROM qvm_new_apps.quotation_items WHERE quotation_id = p_quotation_id;
  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id, part_description, part_number, quantity, brand_class,
    item_status, created_by, created_at, updated_at, line_item_code
  ) VALUES (
    p_quotation_id, NULLIF(p_part_description,''), NULLIF(p_part_number,''),
    COALESCE(p_quantity,1), p_brand_class, v_status_added, v_user, now(), now(), v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  -- link the new item to the submitting vendor only
  INSERT INTO qvm_new_apps.quotation_vendor_items (
    quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost,
    from_database, vendor_item_status, created_at, updated_at
  ) VALUES (
    v_item_id, v_vendor, v_qv_id, false, p_cost, false, NULL, now(), now()
  ) ON CONFLICT (quotation_item_id, vendor_id) DO NOTHING;

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items', p_type_id := v_item_id,
        p_note_description := p_note, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','quotation_item_id', v_item_id, 'line_item_code', v_line_item_code);
END;
$$;
REVOKE ALL ON FUNCTION public.add_quotation_item_by_vendor(int,text,text,int,int,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_quotation_item_by_vendor(int,text,text,int,int,numeric,text) TO authenticated;

-- 4) Admin reviews (accept/reject) a vendor-added item.
CREATE OR REPLACE FUNCTION public.review_vendor_added_item(
  p_quotation_item_id bigint,
  p_action text,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_allowed boolean;
  v_cur int; v_added int; v_sent int; v_cancel int; v_new int;
  v_qid bigint; v_creator uuid; v_email text;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','error','message','Not authenticated'); END IF;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_user
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager'))
  ) INTO v_allowed;
  IF NOT v_allowed THEN RETURN jsonb_build_object('status','error','message','Not authorized'); END IF;

  SELECT list_data_id INTO v_added  FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;
  SELECT list_data_id INTO v_sent   FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor' LIMIT 1;
  SELECT list_data_id INTO v_cancel FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Cancelled' LIMIT 1;

  SELECT item_status, quotation_id, created_by INTO v_cur, v_qid, v_creator
  FROM qvm_new_apps.quotation_items WHERE quotation_item_id = p_quotation_item_id;
  IF v_cur IS NULL THEN RETURN jsonb_build_object('status','error','message','Item not found'); END IF;
  IF v_cur <> v_added THEN RETURN jsonb_build_object('status','error','message','Item is not pending vendor approval'); END IF;

  IF lower(p_action) = 'accept' THEN v_new := v_sent;
  ELSIF lower(p_action) = 'reject' THEN v_new := v_cancel;
  ELSE RETURN jsonb_build_object('status','error','message','Invalid action'); END IF;

  UPDATE qvm_new_apps.quotation_items SET item_status = v_new, updated_at = now()
  WHERE quotation_item_id = p_quotation_item_id;

  IF v_new = v_cancel AND p_reason IS NOT NULL AND btrim(p_reason) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items', p_type_id := p_quotation_item_id,
        p_note_description := 'Rejected: ' || p_reason, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  IF v_new = v_cancel AND v_creator IS NOT NULL THEN
    BEGIN
      SELECT email INTO v_email FROM qvm_new_apps.user_data WHERE user_id = v_creator;
      IF v_email IS NOT NULL THEN
        PERFORM net.http_post(
          url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/resend-notify',
          headers := jsonb_build_object('Content-Type','application/json'),
          body := jsonb_build_object('to', v_email, 'subject', 'Suggested item not accepted',
            'html', '<p>Your suggested item on order ' || v_qid::text || ' was not accepted.' ||
                    CASE WHEN p_reason IS NOT NULL THEN ' Reason: ' || p_reason ELSE '' END || '</p>'));
      END IF;
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','action', lower(p_action), 'new_status', v_new);
END;
$$;
REVOKE ALL ON FUNCTION public.review_vendor_added_item(bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_vendor_added_item(bigint,text,text) TO authenticated;

-- 5) AppSheet timing: do NOT push vendor-suggested items on insert (wait for admin approval).
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_write_item_to_sheet_on_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = net, public
AS $$
BEGIN
  IF NEW.item_status = (SELECT list_data_id FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1) THEN
    RETURN NEW; -- unapproved vendor item; pushed on admin accept instead
  END IF;
  PERFORM net.http_post(
    url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object('quotation_item_id', NEW.quotation_item_id, 'quotation_id', NEW.quotation_id)
  );
  RETURN NEW;
END;
$$;

-- 6) Status-change sync must skip transitions OUT of "Added by Vendor" (accept pushes via #7; reject
--    must not touch the sheet since the row was never added).
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_update_item_status_in_sheet()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = net, public
AS $$
BEGIN
  IF OLD.item_status = (SELECT list_data_id FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1) THEN
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/update_item_status_in_sheet',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object('quotation_item_id', NEW.quotation_item_id)
  );
  RETURN NEW;
END;
$$;

-- 7) On admin accept ("Added by Vendor" -> "Sent To Vendor"), ADD the item to AppSheet.
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_push_vendor_item_on_accept()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = net, public
AS $$
DECLARE v_added int; v_sent int;
BEGIN
  SELECT list_data_id INTO v_added FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;
  SELECT list_data_id INTO v_sent  FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor' LIMIT 1;
  IF OLD.item_status = v_added AND NEW.item_status = v_sent THEN
    PERFORM net.http_post(
      url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body    := jsonb_build_object('quotation_item_id', NEW.quotation_item_id, 'quotation_id', NEW.quotation_id)
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_push_vendor_item_on_accept ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_push_vendor_item_on_accept
  AFTER UPDATE ON qvm_new_apps.quotation_items
  FOR EACH ROW
  WHEN (NEW.item_status IS DISTINCT FROM OLD.item_status)
  EXECUTE FUNCTION qvm_new_apps.trg_push_vendor_item_on_accept();
;
