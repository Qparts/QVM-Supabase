-- QNEW-65: thread the real acting user through to the AppSheet-sync edge functions so
-- appsheet_sync_logs.created_by can be populated. These triggers/RPC fire inside the same
-- Postgres session as the authenticated call that performed the UPDATE/INSERT, so auth.uid()
-- reflects the real actor (NULL when there isn't one, e.g. a service-role-driven change).
-- CREATE OR REPLACE only - none of these change signature/arity, so no DROP FUNCTION needed.

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_update_item_status_in_sheet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'net', 'public'
AS $function$BEGIN
  IF OLD.item_status = (SELECT list_data_id FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1) THEN
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/update_item_status_in_sheet',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('quotation_item_id', NEW.quotation_item_id, 'created_by', auth.uid()));
  RETURN NEW;
END;$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_push_vendor_item_on_accept()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'net', 'public'
AS $function$DECLARE v_added int; v_sent int;
BEGIN
  SELECT list_data_id INTO v_added FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;
  SELECT list_data_id INTO v_sent  FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor' LIMIT 1;
  IF OLD.item_status = v_added AND NEW.item_status = v_sent THEN
    PERFORM net.http_post(
      url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('quotation_item_id', NEW.quotation_item_id, 'quotation_id', NEW.quotation_id, 'created_by', auth.uid()));
  END IF;
  RETURN NEW;
END;$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_write_price_to_sheet_on_priced_stmt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'extensions', 'public'
AS $function$
DECLARE
  v_url text := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_price_to_sheet';
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_ids jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(n.quotation_item_id), '[]'::jsonb)
  INTO v_ids
  FROM new_rows n
  JOIN old_rows o ON o.quotation_item_id = n.quotation_item_id
  WHERE n.item_status = 17 OR n.price_before_vat IS DISTINCT FROM o.price_before_vat;

  IF jsonb_array_length(v_ids) > 0 THEN
    PERFORM net.http_post(v_url, jsonb_build_object('quotation_item_ids', v_ids, 'created_by', auth.uid()), '{}'::jsonb, v_headers, 10000);
  END IF;

  RETURN NULL;
END;$function$;

CREATE OR REPLACE FUNCTION public.add_rfq_item_inline(p_quotation_id integer, p_part_number text DEFAULT NULL::text, p_part_description text DEFAULT NULL::text, p_quantity integer DEFAULT 1, p_brand_class integer DEFAULT NULL::integer, p_part_photo text DEFAULT NULL::text, p_initial_note text DEFAULT NULL::text, p_from_frontend boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_order_number text;
  v_next_index int;
  v_line_item_code text;
  v_item_id int;
  v_brand_class_name text;
  v_item_status int;
BEGIN
  v_item_status := CASE
    WHEN p_part_number IS NOT NULL AND btrim(p_part_number) <> '' THEN 235
    ELSE 236
  END;
  SELECT order_number INTO v_order_number
  FROM qvm_new_apps.quotations
  WHERE quotation_id = p_quotation_id;

  IF v_order_number IS NULL THEN
    RETURN jsonb_build_object('status','error','message','Invalid quotation_id','quotation_item_id', NULL);
  END IF;

  SELECT COALESCE(
    MAX(
      NULLIF(regexp_replace(COALESCE(line_item_code, ''), '^.*-([0-9]+)$', '\1'), '')::int
    ), 0
  ) + 1
  INTO v_next_index
  FROM qvm_new_apps.quotation_items
  WHERE quotation_id = p_quotation_id;

  v_line_item_code := v_order_number || '-' || v_next_index;

  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    part_description,
    part_number,
    quantity,
    brand_class,
    part_photo,
    item_status,
    created_by,
    created_at,
    updated_at,
    line_item_code
  ) VALUES (
    p_quotation_id,
    NULLIF(p_part_description, ''),
    NULLIF(p_part_number, ''),
    COALESCE(p_quantity, 1),
    p_brand_class,
    p_part_photo,
    v_item_status,
    auth.uid(),
    NOW(),
    NOW(),
    v_line_item_code
  ) RETURNING quotation_item_id INTO v_item_id;

  IF p_initial_note IS NOT NULL AND btrim(p_initial_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items',
        p_type_id := v_item_id,
        p_note_description := p_initial_note,
        p_note_id := NULL,
        p_is_internal := false
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  SELECT list_data INTO v_brand_class_name FROM qvm_new_apps.list_data WHERE list_data_id = p_brand_class;

  IF p_from_frontend THEN
    BEGIN
      PERFORM net.http_post(
        url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet',
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body    := jsonb_build_object('quotation_item_id', v_item_id, 'quotation_id', p_quotation_id, 'created_by', auth.uid())
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'message','Item added',
    'quotation_item_id', v_item_id,
    'item_status_id', v_item_status,
    'brand_class_id', p_brand_class,
    'brand_class', v_brand_class_name
  );
END;
$function$;
