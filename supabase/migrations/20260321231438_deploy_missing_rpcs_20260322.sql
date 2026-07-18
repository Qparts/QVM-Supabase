-- Synced from QVM/test branch applied migration history (version 20260321231438, name: deploy_missing_rpcs_20260322)
BEGIN;

-- Wrapper: get_clients_rows
CREATE OR REPLACE FUNCTION public.get_clients_rows(p_list_id integer DEFAULT 1)
RETURNS TABLE(list_data_id integer, list_data text)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','qvm_new_apps'
AS $$
  SELECT ld.list_data_id, ld.list_data
  FROM qvm_new_apps.list_data ld
  WHERE ld.list_id = COALESCE(p_list_id, 1)
  ORDER BY ld.list_data;
$$;
REVOKE EXECUTE ON FUNCTION public.get_clients_rows(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_clients_rows(integer) TO authenticated;

-- Wrapper: get_client_branches_rows
CREATE OR REPLACE FUNCTION public.get_client_branches_rows(p_client_id integer DEFAULT NULL)
RETURNS TABLE(customer_id integer, branch_name text, list_data_id integer)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public','pg_temp'
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_client_id IS NULL THEN
    RETURN QUERY
    SELECT cb.customer_id, cb.branch_name, cb.list_data_id
    FROM client_branches cb
    ORDER BY cb.branch_name;
  ELSE
    RETURN QUERY
    SELECT cb.customer_id, cb.branch_name, cb.list_data_id
    FROM client_branches cb
    WHERE cb.list_data_id = p_client_id
    ORDER BY cb.branch_name;
  END IF;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.get_client_branches_rows(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_client_branches_rows(integer) TO authenticated;

-- Inline edit and notes RPCs copied from production

-- update_quotation_item_inline
CREATE OR REPLACE FUNCTION public.update_quotation_item_inline(
  p_quotation_item_id integer,
  p_part_description text DEFAULT NULL,
  p_part_number text DEFAULT NULL,
  p_alternative_part_number text DEFAULT NULL,
  p_part_category integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
declare
  v_uid uuid;
  v_user_type int;
  v_current_desc text;
  v_current_num text;
  v_rows int;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  select user_type into v_user_type from user_data where user_id = v_uid;
  if v_user_type <> 185 then
    raise exception 'Access denied: Internal users only';
  end if;

  if p_part_category is not null then
    perform 1 from list_data where list_data_id = p_part_category;
    if not found then
      raise exception 'Invalid part_category (list_data_id %) provided', p_part_category;
    end if;
  end if;

  select part_description, part_number into v_current_desc, v_current_num
  from quotation_items where quotation_item_id = p_quotation_item_id;

  if not found then
    raise exception 'quotation_item_id % not found', p_quotation_item_id;
  end if;

  -- Validate: part description and part number cannot both be empty after update
  if coalesce(nullif(coalesce(p_part_description, v_current_desc), ''), '') = ''
     and coalesce(nullif(coalesce(p_part_number, v_current_num), ''), '') = '' then
    raise exception 'Part Description and Part Number cannot both be empty';
  end if;

  update quotation_items qi
  set
    part_description = coalesce(p_part_description, qi.part_description),
    part_number = coalesce(p_part_number, qi.part_number),
    alternative_part_number = coalesce(p_alternative_part_number, qi.alternative_part_number),
    part_category = coalesce(p_part_category, qi.part_category)
  where quotation_item_id = p_quotation_item_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'No changes applied';
  end if;

  return jsonb_build_object('status', 'success', 'message', 'quotation_item updated');
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.update_quotation_item_inline(integer, text, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_quotation_item_inline(integer, text, text, text, integer) TO authenticated;

-- update_confirmed_item_inline
CREATE OR REPLACE FUNCTION public.update_confirmed_item_inline(
  p_quotation_item_id integer,
  p_approved_qty integer DEFAULT NULL,
  p_return_type integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
declare
  v_uid uuid;
  v_user_type int;
  v_rows int;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  select user_type into v_user_type from user_data where user_id = v_uid;
  if v_user_type <> 185 then
    raise exception 'Access denied: Internal users only';
  end if;

  if p_approved_qty is not null and p_approved_qty < 0 then
    raise exception 'Approved quantity must be >= 0';
  end if;

  if p_return_type is not null then
    perform 1 from list_data where list_data_id = p_return_type;
    if not found then
      raise exception 'Invalid return_type (list_data_id %) provided', p_return_type;
    end if;
  end if;

  update confirmed_items ci
  set
    approved_qty = coalesce(p_approved_qty, ci.approved_qty),
    return_type = coalesce(p_return_type, ci.return_type)
  where ci.quotation_item_id = p_quotation_item_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'confirmed_item for quotation_item_id % not found', p_quotation_item_id;
  end if;

  return jsonb_build_object('status', 'success', 'message', 'confirmed_item updated');
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.update_confirmed_item_inline(integer, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_confirmed_item_inline(integer, integer, integer) TO authenticated;

-- update_purchase_account_inline
CREATE OR REPLACE FUNCTION public.update_purchase_account_inline(
  p_confirmed_order_id integer,
  p_payment_account integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_user_type int;
  v_rows int;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = v_uid;
  IF v_user_type <> 185 THEN
    RAISE EXCEPTION 'Access denied: Internal users only';
  END IF;

  -- Validate payment_account exists in list_data
  PERFORM 1 FROM list_data WHERE list_data_id = p_payment_account;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid payment_account (list_data_id %) provided', p_payment_account;
  END IF;

  UPDATE purchase_orders po
  SET payment_account = p_payment_account
  WHERE po.confirmed_order_id = p_confirmed_order_id;
  GET DIAGNOSTICS v_rows = row_count;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'purchase_orders row for confirmed_order_id % not found', p_confirmed_order_id;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'message', 'payment_account updated');
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.update_purchase_account_inline(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_purchase_account_inline(integer, integer) TO authenticated;

-- upsert_note_inline
CREATE OR REPLACE FUNCTION public.upsert_note_inline(
  p_note_type text,
  p_type_id integer,
  p_note_description text,
  p_note_id integer DEFAULT NULL,
  p_is_internal boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_user_type int;
  v_new_note_id int;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = v_uid;
  IF v_user_type <> 185 THEN
    RAISE EXCEPTION 'Access denied: Internal users only';
  END IF;

  -- Validate note_type
  IF p_note_type NOT IN ('quotations', 'quotation_items') THEN
    RAISE EXCEPTION 'Invalid note_type. Must be quotations or quotation_items';
  END IF;

  -- Validate note_description
  IF p_note_description IS NULL OR trim(p_note_description) = '' THEN
    RAISE EXCEPTION 'Note description cannot be empty';
  END IF;

  -- Update existing note
  IF p_note_id IS NOT NULL THEN
    UPDATE notes
    SET 
      note_description = p_note_description,
      updated_at = now()
    WHERE note_id = p_note_id
      AND user_id = v_uid; -- Only allow editing own notes
    
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Note % not found or you do not have permission to edit it', p_note_id;
    END IF;
    
    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Note updated',
      'note_id', p_note_id
    );
  
  -- Insert new note
  ELSE
    INSERT INTO notes (
      note_type,
      type_id,
      note_description,
      user_id,
      is_internal,
      created_at
    ) VALUES (
      p_note_type,
      p_type_id,
      p_note_description,
      v_uid,
      p_is_internal,
      now()
    )
    RETURNING note_id INTO v_new_note_id;
    
    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Note created',
      'note_id', v_new_note_id
    );
  END IF;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.upsert_note_inline(text, integer, text, integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_note_inline(text, integer, text, integer, boolean) TO authenticated;

-- delete_note_inline
CREATE OR REPLACE FUNCTION public.delete_note_inline(
  p_note_id integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_user_type int;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = v_uid;
  IF v_user_type <> 185 THEN
    RAISE EXCEPTION 'Access denied: Internal users only';
  END IF;

  DELETE FROM notes
  WHERE note_id = p_note_id
    AND user_id = v_uid; -- Only allow deleting own notes
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Note % not found or you do not have permission to delete it', p_note_id;
  END IF;
  
  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Note deleted'
  );
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.delete_note_inline(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_note_inline(integer) TO authenticated;

-- add_rfq_item_inline
CREATE OR REPLACE FUNCTION public.add_rfq_item_inline(
  p_quotation_id integer,
  p_part_number text,
  p_part_description text,
  p_quantity integer,
  p_brand_class integer,
  p_part_photo text DEFAULT NULL,
  p_initial_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_user_type int;
  v_qi_id int;
  v_new_status_id int;
  v_brand_class_name text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = v_uid;
  IF v_user_type <> 185 THEN
    RAISE EXCEPTION 'Access denied: Internal users only';
  END IF;

  IF COALESCE(trim(p_part_number),'') = '' AND COALESCE(trim(p_part_description),'') = '' THEN
    RAISE EXCEPTION 'Part Number and Part Description cannot both be empty';
  END IF;
  IF p_brand_class IS NULL THEN
    RAISE EXCEPTION 'Brand Class is required';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be > 0';
  END IF;

  SELECT ld.list_data_id
  INTO v_new_status_id
  FROM list_data ld
  JOIN lists l ON l.list_id = ld.list_id
  WHERE lower(l.list_name) IN ('item_status','rfq_status','status')
    AND lower(ld.list_data) IN ('new rfq','new_rfq','new rfq item','new')
  ORDER BY CASE WHEN lower(l.list_name) = 'item_status' THEN 0 ELSE 1 END, ld.list_data_id
  LIMIT 1;

  INSERT INTO quotation_items (
    quotation_id,
    part_description,
    part_number,
    quantity,
    brand_class,
    part_photo,
    item_status
  ) VALUES (
    p_quotation_id,
    NULLIF(trim(p_part_description),''),
    NULLIF(trim(p_part_number),''),
    p_quantity,
    p_brand_class,
    NULLIF(trim(p_part_photo),''),
    v_new_status_id
  ) RETURNING quotation_item_id INTO v_qi_id;

  INSERT INTO status_logs(quotation_item_id, item_status, status_changed_by)
  VALUES (v_qi_id, v_new_status_id, v_uid);

  IF p_initial_note IS NOT NULL AND trim(p_initial_note) <> '' THEN
    INSERT INTO notes(note_type, type_id, note_description, user_id, is_internal, created_at)
    VALUES ('quotation_items', v_qi_id, p_initial_note, v_uid, false, now());
  END IF;

  SELECT ld.list_data INTO v_brand_class_name FROM list_data ld WHERE ld.list_data_id = p_brand_class;

  RETURN jsonb_build_object(
    'status','success',
    'message','Item added to RFQ successfully',
    'quotation_item_id', v_qi_id,
    'item_status_id', v_new_status_id,
    'brand_class_id', p_brand_class,
    'brand_class', v_brand_class_name
  );
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.add_rfq_item_inline(integer, text, text, integer, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_rfq_item_inline(integer, text, text, integer, integer, text, text) TO authenticated;

-- change_item_status_bulk
CREATE OR REPLACE FUNCTION public.change_item_status_bulk(
  p_quotation_item_ids integer[],
  p_new_status_id integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_user_type int;
  v_new_status_label text;
  v_blocked_ids int[];
  v_any_blocked int;
  v_updated_q int;
  v_updated_c int;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = v_uid;
  IF v_user_type <> 185 THEN
    RAISE EXCEPTION 'Access denied: Internal users only';
  END IF;

  SELECT ld.list_data INTO v_new_status_label FROM list_data ld WHERE ld.list_data_id = p_new_status_id;
  IF v_new_status_label IS NULL THEN
    RAISE EXCEPTION 'Invalid new status id %', p_new_status_id;
  END IF;

  SELECT array_agg(ld.list_data_id)
  INTO v_blocked_ids
  FROM list_data ld
  JOIN lists l ON l.list_id = ld.list_id
  WHERE lower(l.list_name) IN ('item_status','rfq_status','status')
    AND lower(ld.list_data) IN (
      'pending invoice','pending credit note','invoice issued','credit note issued','claim sent','settled'
    );

  SELECT COUNT(*) INTO v_any_blocked
  FROM (
    SELECT qi.item_status AS st
    FROM quotation_items qi
    WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
    UNION ALL
    SELECT ci.item_status AS st
    FROM confirmed_items ci
    WHERE ci.quotation_item_id = ANY(p_quotation_item_ids)
  ) s
  WHERE s.st = ANY(v_blocked_ids);

  IF COALESCE(v_any_blocked,0) > 0 THEN
    RAISE EXCEPTION 'Selected items cannot be updated because their current status does not allow changes.';
  END IF;

  WITH q_to_update AS (
    SELECT qi.quotation_item_id
    FROM quotation_items qi
    LEFT JOIN confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
    WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
      AND ci.confirmed_item_id IS NULL
  )
  UPDATE quotation_items qi
  SET item_status = p_new_status_id
  FROM q_to_update u
  WHERE qi.quotation_item_id = u.quotation_item_id;
  GET DIAGNOSTICS v_updated_q = ROW_COUNT;

  INSERT INTO status_logs(quotation_item_id, item_status, status_changed_by)
  SELECT u.quotation_item_id, p_new_status_id, v_uid FROM (
    SELECT qi.quotation_item_id
    FROM quotation_items qi
    LEFT JOIN confirmed_items ci ON ci.quotation_item_id = qi.quotation_item_id
    WHERE qi.quotation_item_id = ANY(p_quotation_item_ids)
      AND ci.confirmed_item_id IS NULL
  ) u;

  WITH c_to_update AS (
    SELECT ci.confirmed_item_id
    FROM confirmed_items ci
    WHERE ci.quotation_item_id = ANY(p_quotation_item_ids)
  )
  UPDATE confirmed_items ci
  SET item_status = p_new_status_id
  FROM c_to_update u
  WHERE ci.confirmed_item_id = u.confirmed_item_id;
  GET DIAGNOSTICS v_updated_c = ROW_COUNT;

  INSERT INTO status_logs(confirmed_item_id, item_status, status_changed_by)
  SELECT ci.confirmed_item_id, p_new_status_id, v_uid
  FROM confirmed_items ci
  WHERE ci.quotation_item_id = ANY(p_quotation_item_ids);

  RETURN jsonb_build_object(
    'status','success',
    'message','Statuses updated successfully',
    'updated_count', COALESCE(v_updated_q,0) + COALESCE(v_updated_c,0)
  );
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.change_item_status_bulk(integer[], integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_item_status_bulk(integer[], integer) TO authenticated;

COMMIT;;
