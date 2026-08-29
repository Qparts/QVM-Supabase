-- Ports 112 functions from QVM/test backing the features added in
-- 20260829120000_port_qvm_test_tables.sql (wa_*, upload_*, pricing_*, customer_*, email_*,
-- extract_* / part_* helpers). Extracted verbatim via pg_get_functiondef from QVM/test;
-- qvm_new_apps-schema functions are created before public-schema wrappers that call them
-- (mirrors this app's public-wrapper-calls-qvm_new_apps convention).

-- qvm_new_apps._log_extract_event(p_quotation_item_id integer, p_event_type text, p_old text, p_new text)
CREATE OR REPLACE FUNCTION qvm_new_apps._log_extract_event(p_quotation_item_id integer, p_event_type text, p_old text DEFAULT NULL::text, p_new text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into qvm_new_apps.quotation_item_extraction_events
    (quotation_item_id, quotation_id, event_type, old_value, new_value, actor)
  select p_quotation_item_id, qi.quotation_id, p_event_type,
         nullif(p_old, ''), nullif(p_new, ''), auth.uid()
  from qvm_new_apps.quotation_items qi
  where qi.quotation_item_id = p_quotation_item_id;
$function$;
-- qvm_new_apps._touch_extract_lock(p_quotation_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps._touch_extract_lock(p_quotation_id integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update qvm_new_apps.quotations
  set extract_lock_touched_at = now()
  where quotation_id = p_quotation_id and extract_locked_by = auth.uid();
$function$;
-- qvm_new_apps.add_extract_alt_pn(p_quotation_item_id integer, p_alt text)
CREATE OR REPLACE FUNCTION qvm_new_apps.add_extract_alt_pn(p_quotation_item_id integer, p_alt text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_alt text; v_primary text; v_qid integer;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  v_alt := upper(btrim(coalesce(p_alt, '')));
  if length(v_alt) < 3 then return jsonb_build_object('status', false, 'message', 'Part number must be at least 3 characters'); end if;

  select quotation_id, upper(btrim(coalesce(nullif(part_number,''), draft_part_number, '')))
    into v_qid, v_primary
  from qvm_new_apps.quotation_items where quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;
  if v_alt = v_primary then return jsonb_build_object('status', false, 'message', 'Alternate cannot equal the primary part number'); end if;
  if exists (select 1 from qvm_new_apps.quotation_item_alt_pns
             where quotation_item_id = p_quotation_item_id and alt_part_number = v_alt) then
    return jsonb_build_object('status', false, 'message', 'This alternate is already added');
  end if;

  insert into qvm_new_apps.quotation_item_alt_pns (quotation_item_id, alt_part_number, created_by)
  values (p_quotation_item_id, v_alt, v_uid);
  perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'alt_added', null, v_alt);
  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'OK');
end $function$;
-- qvm_new_apps.add_extract_item(p_quotation_id integer, p_part_description text, p_part_number text, p_alt_part_number text)
CREATE OR REPLACE FUNCTION qvm_new_apps.add_extract_item(p_quotation_id integer, p_part_description text, p_part_number text DEFAULT NULL::text, p_alt_part_number text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lock uuid;
  v_res  jsonb;
  v_id   int;
  v_desc text := btrim(coalesce(p_part_description, ''));
  v_pn   text := nullif(btrim(coalesce(p_part_number, '')), '');
  v_alt  text := nullif(btrim(coalesce(p_alt_part_number, '')), '');
begin
  if v_desc = '' then
    return jsonb_build_object('status', false, 'message', 'Part description is required');
  end if;

  select extract_locked_by into v_lock
  from qvm_new_apps.quotations
  where quotation_id = p_quotation_id;

  if v_lock is not null and v_lock <> auth.uid() then
    return jsonb_build_object('status', false, 'message', 'This order is locked by another extractor');
  end if;

  -- Always add without a part number so the item lands in Extract PN (236), never 235.
  v_res := public.add_rfq_item_inline(
    p_quotation_id   := p_quotation_id,
    p_part_number    := null,
    p_part_description := v_desc,
    p_quantity       := 1,
    p_brand_class    := null,
    p_part_photo     := null,
    p_initial_note   := null,
    p_from_frontend  := true
  );

  if coalesce(v_res ->> 'status', '') <> 'success' then
    return jsonb_build_object('status', false, 'message', coalesce(v_res ->> 'message', 'Could not add the item'));
  end if;

  v_id := (v_res ->> 'quotation_item_id')::int;

  update qvm_new_apps.quotation_items
     set added_at_extraction = true,
         draft_part_number   = case when v_pn is not null then upper(v_pn) end,
         pn_state            = case when v_pn is not null then 'draft' else 'none' end,
         updated_at          = now()
   where quotation_item_id = v_id;

  perform qvm_new_apps._log_extract_event(v_id, 'item_added', null, v_desc);

  if v_alt is not null then
    insert into qvm_new_apps.quotation_item_alt_pns (quotation_item_id, alt_part_number, created_by)
    values (v_id, upper(v_alt), auth.uid())
    on conflict do nothing;
    perform qvm_new_apps._log_extract_event(v_id, 'alt_added', null, upper(v_alt));
  end if;

  perform qvm_new_apps._touch_extract_lock(p_quotation_id);

  return jsonb_build_object('status', true, 'message', 'Item added',
                            'data', jsonb_build_object('quotation_item_id', v_id));
end;
$function$;
-- qvm_new_apps.add_note(p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text, p_note_attachment text)
CREATE OR REPLACE FUNCTION qvm_new_apps.add_note(p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text, p_note_attachment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_note_id INTEGER;
    v_user_id UUID := auth.uid(); -- Authenticated user
    result JSONB;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'status', false,
            'message', 'Unauthorized: user_id is null',
            'data', NULL
        );
    END IF;

    INSERT INTO qvm_new_apps.notes (
        note_type,
        type_id,
        user_id,
        is_internal,
        note_description,
        note_attachment,
        created_at,
        updated_at
    )
    VALUES (
        p_note_type,
        p_type_id,
        v_user_id,
        p_is_internal,
        p_note_description,
        p_note_attachment,
        NOW(),
        NOW()
    )
    RETURNING note_id INTO v_note_id;

    SELECT jsonb_build_object(
        'status', true,
        'message', 'Note added successfully',
        'data', jsonb_build_object(
            'note_id', v_note_id,
            'note_type', p_note_type,
            'type_id', p_type_id,
            'user_id', v_user_id,
            'is_internal', p_is_internal,
            'note_description', p_note_description,
            'note_attachment', p_note_attachment
        )
    )
    INTO result;

    RETURN result;
END;
$function$;
-- qvm_new_apps.branch_order_addresses(p_branch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.branch_order_addresses(p_branch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_rows jsonb; v_kind_available boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'address_id', a.address_id,
           'label', a.label,
           'address_line', a.address_line,
           'city', a.city,
           'region_id', a.region_id,
           'contact_name', a.contact_name,
           'contact_phone', a.contact_phone,
           'is_default', a.is_default)
         -- Default first: it is the one the header pre-selects.
         order by a.is_default desc, a.address_id), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.customer_addresses a
   where a.client_branch_id = p_branch_id
     and a.is_active
     and a.receives_orders;

  -- «عرض سعر» only exists for a customer whose approvals are on, so the header
  -- learns here whether to offer the choice at all rather than offering it and
  -- failing at submit.
  select coalesce(bool_or(c.approvals_enabled), false) into v_kind_available
    from qvm_new_apps.client_branches b
    join qvm_new_apps.customers c on c.list_data_id = b.list_data_id and c.merged_into is null
   where b.customer_id = p_branch_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'addresses', v_rows,
    'quote_kind_available', v_kind_available));
end
$function$;
-- qvm_new_apps.create_quotation_with_items(p_account_manager uuid, p_delivery_type integer, p_order_type integer, p_plate_number text, p_service_advisor uuid, p_client_id integer, p_region_id integer, p_customer_id bigint, p_items jsonb, p_insurance_company_id bigint, p_order_number text, p_notes text, p_request_kind text, p_customer_address_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.create_quotation_with_items(p_account_manager uuid, p_delivery_type integer, p_order_type integer, p_plate_number text, p_service_advisor uuid, p_client_id integer, p_region_id integer, p_customer_id bigint, p_items jsonb, p_insurance_company_id bigint, p_order_number text, p_notes text, p_request_kind text DEFAULT 'purchase'::text, p_customer_address_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation qvm_new_apps.quotations;
  v_order_number text;
  v_item jsonb;
  v_items_payload jsonb := '[]'::jsonb;
  v_est numeric;
  v_inserted_items jsonb;
  v_kind text;
  v_addr bigint;
BEGIN
  IF NOT jsonb_typeof(p_items) = 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Items are required';
  END IF;

  v_kind := lower(nullif(btrim(coalesce(p_request_kind, '')), ''));
  IF v_kind IS NULL THEN v_kind := 'purchase'; END IF;
  IF v_kind NOT IN ('quote', 'purchase') THEN
    RAISE EXCEPTION 'نوع الطلب غير معروف: %', p_request_kind;
  END IF;

  -- «عرض سعر» is only on offer to a customer whose approvals are switched on:
  -- the priced offer has to route through someone, and with approvals off
  -- there is nobody to route it to.
  IF v_kind = 'quote' AND NOT EXISTS (
       SELECT 1 FROM qvm_new_apps.customers c
        WHERE c.list_data_id = p_client_id AND c.approvals_enabled AND c.merged_into IS NULL) THEN
    RAISE EXCEPTION 'هذا العميل لا تُفعَّل عنده الاعتمادات، فلا يمكن إنشاء «عرض سعر»';
  END IF;

  -- An address belonging to someone else, switched off, or not meant to
  -- receive orders is not an address this order can be sent to.
  IF p_customer_address_id IS NOT NULL THEN
    SELECT a.address_id INTO v_addr
      FROM qvm_new_apps.customer_addresses a
      JOIN qvm_new_apps.customers c ON c.customer_id = a.customer_id
     WHERE a.address_id = p_customer_address_id
       AND c.list_data_id = p_client_id
       AND a.is_active
       AND a.receives_orders;
    IF v_addr IS NULL THEN
      RAISE EXCEPTION 'العنوان المختار لا يخص هذا العميل أو لا يستقبل طلبات';
    END IF;
  END IF;

  v_order_number := NULLIF(btrim(p_order_number), '');
  IF v_order_number IS NULL THEN
    v_order_number := qvm_new_apps.generate_rfq_order_number(p_client_id, p_region_id);
  END IF;

  INSERT INTO qvm_new_apps.quotations (
    order_number, plate_number, order_type, delivery_type, service_advisor, account_manager,
    shipping_type, insurance_company_id, request_kind, customer_address_id
  ) VALUES (
    v_order_number, p_plate_number, p_order_type, p_delivery_type, p_service_advisor,
    p_account_manager, 'item', p_insurance_company_id, v_kind, v_addr
  ) RETURNING * INTO v_quotation;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_est := public.get_estimated_price(
      p_client_id := p_client_id,
      p_part_number := v_item->>'part_number',
      p_brand_class_id := (v_item->>'brand_class')::integer
    );
    v_items_payload := v_items_payload || jsonb_build_object(
      'quotation_id', v_quotation.quotation_id,
      'customer_id', p_customer_id,
      'vin', v_item->'vin',
      'main_brand', v_item->'main_brand',
      'model', v_item->'model',
      'part_number', v_item->'part_number',
      'part_description', v_item->'part_description',
      'quantity', v_item->'quantity',
      'brand_class', v_item->'brand_class',
      'part_photo', v_item->'part_photo',
      'item_status', CASE WHEN COALESCE(v_item->>'part_number', '') <> '' THEN 235 ELSE 236 END,
      'item_PK', v_item->'item_PK',
      'estimated_price', v_est
    );
  END LOOP;

  SELECT jsonb_agg(to_jsonb(t)) INTO v_inserted_items
  FROM public.create_quotation_items(v_items_payload) t;

  IF p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN
    PERFORM public.create_quotation_note(v_quotation.quotation_id, p_notes, p_service_advisor);
  END IF;

  RETURN jsonb_build_object(
    'quotation_id', v_quotation.quotation_id,
    'order_number', v_quotation.order_number,
    'request_kind', v_quotation.request_kind,
    'customer_address_id', v_quotation.customer_address_id,
    'items', COALESCE(v_inserted_items, '[]'::jsonb)
  );
END;
$function$;
-- qvm_new_apps.current_upload_vendor_id()
CREATE OR REPLACE FUNCTION qvm_new_apps.current_upload_vendor_id()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  select u.user_vendor from qvm_new_apps.user_data u
   where u.user_id = auth.uid() and u.user_type = 205 and u.user_vendor is not null
   limit 1;
$function$;
-- qvm_new_apps.customer_address_save(p_customer_id bigint, p_address_id bigint, p_client_branch_id bigint, p_label text, p_address_line text, p_city text, p_region_id integer, p_contact_name text, p_contact_phone text, p_receives_orders boolean, p_receives_shipments boolean, p_is_default boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_address_save(p_customer_id bigint, p_address_id bigint DEFAULT NULL::bigint, p_client_branch_id bigint DEFAULT NULL::bigint, p_label text DEFAULT NULL::text, p_address_line text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_region_id integer DEFAULT NULL::integer, p_contact_name text DEFAULT NULL::text, p_contact_phone text DEFAULT NULL::text, p_receives_orders boolean DEFAULT true, p_receives_shipments boolean DEFAULT true, p_is_default boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_id bigint; v_before jsonb; v_after jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_address_line,'')), '') is null then
    return jsonb_build_object('status', false, 'message', 'العنوان مطلوب', 'data', null);
  end if;

  -- One default per branch: clear the old one first, or the partial unique
  -- index rejects the write.
  if p_is_default and p_client_branch_id is not null then
    update qvm_new_apps.customer_addresses
       set is_default = false, updated_at = now()
     where client_branch_id = p_client_branch_id and is_default
       and (p_address_id is null or address_id <> p_address_id);
  end if;

  if p_address_id is null then
    insert into qvm_new_apps.customer_addresses (
      customer_id, client_branch_id, label, address_line, city, region_id,
      contact_name, contact_phone, receives_orders, receives_shipments, is_default, created_by)
    values (p_customer_id, p_client_branch_id, p_label, btrim(p_address_line), p_city, p_region_id,
            p_contact_name, p_contact_phone, p_receives_orders, p_receives_shipments,
            p_is_default, auth.uid())
    returning address_id, to_jsonb(customer_addresses) into v_id, v_after;
  else
    select to_jsonb(a) into v_before from qvm_new_apps.customer_addresses a where a.address_id = p_address_id;
    update qvm_new_apps.customer_addresses a set
      client_branch_id = coalesce(p_client_branch_id, a.client_branch_id),
      label = coalesce(p_label, a.label),
      address_line = btrim(p_address_line),
      city = coalesce(p_city, a.city),
      region_id = coalesce(p_region_id, a.region_id),
      contact_name = coalesce(p_contact_name, a.contact_name),
      contact_phone = coalesce(p_contact_phone, a.contact_phone),
      receives_orders = p_receives_orders,
      receives_shipments = p_receives_shipments,
      is_default = p_is_default,
      updated_at = now()
    where a.address_id = p_address_id and a.customer_id = p_customer_id
    returning a.address_id, to_jsonb(a) into v_id, v_after;

    if v_id is null then
      return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
    end if;
  end if;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, before, after, changed_by)
  values (p_customer_id, 'address', v_id,
          case when p_address_id is null then 'create' else 'update' end,
          v_before, v_after, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
                            'data', jsonb_build_object('address_id', v_id));
end
$function$;
-- qvm_new_apps.customer_address_set_active(p_address_id bigint, p_active boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_address_set_active(p_address_id bigint, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_before jsonb; v_cust bigint; v_uses int;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select to_jsonb(a), a.customer_id into v_before, v_cust
    from qvm_new_apps.customer_addresses a where a.address_id = p_address_id;
  if v_before is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  select count(*) into v_uses
    from qvm_new_apps.quotations q where q.customer_address_id = p_address_id;

  update qvm_new_apps.customer_addresses
     set is_active  = p_active,
         is_default = case when p_active then is_default else false end,
         updated_at = now()
   where address_id = p_address_id;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, before, changed_by)
  values (v_cust, 'address', p_address_id, 'update', v_before, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('is_active', p_active, 'orders_still_pointing_here', v_uses));
end
$function$;
-- qvm_new_apps.customer_create(p_name_en text, p_name_ar text, p_customer_type text, p_cr_number text, p_vat_number text, p_contact_person text, p_phone text, p_email text, p_region_id integer, p_customer_code text, p_branch_name text, p_branch_city text, p_order_category integer, p_account_manager uuid, p_order_prefix text, p_address_line text, p_address_label text, p_contact_phone text, p_source text)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_create(p_name_en text, p_name_ar text DEFAULT NULL::text, p_customer_type text DEFAULT NULL::text, p_cr_number text DEFAULT NULL::text, p_vat_number text DEFAULT NULL::text, p_contact_person text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_region_id integer DEFAULT NULL::integer, p_customer_code text DEFAULT NULL::text, p_branch_name text DEFAULT NULL::text, p_branch_city text DEFAULT NULL::text, p_order_category integer DEFAULT NULL::integer, p_account_manager uuid DEFAULT NULL::uuid, p_order_prefix text DEFAULT NULL::text, p_address_line text DEFAULT NULL::text, p_address_label text DEFAULT NULL::text, p_contact_phone text DEFAULT NULL::text, p_source text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_name    text := nullif(btrim(coalesce(p_name_en, '')), '');
  v_cr      text := nullif(btrim(coalesce(p_cr_number, '')), '');
  v_vat     text := nullif(btrim(coalesce(p_vat_number, '')), '');
  v_dupe    record;
  v_list_id integer;
  v_cust    bigint;
  v_branch  bigint;
  v_addr    bigint;
  v_prefix  text;
  v_seq_exists boolean;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_name is null then
    return jsonb_build_object('status', false, 'message', 'اسم العميل مطلوب', 'data', null);
  end if;
  if p_source not in ('manual', 'auto') then
    return jsonb_build_object('status', false, 'message', 'invalid source', 'data', null);
  end if;

  -- Duplicate check before anything is written, so the caller can offer «دمج»
  -- instead of creating a second record for the same company.
  select c.customer_id, c.customer_code, c.source, ld.list_data as name,
         case when v_cr is not null and lower(btrim(c.cr_number)) = lower(v_cr) then 'cr'
              when v_vat is not null and lower(btrim(c.vat_number)) = lower(v_vat) then 'vat'
              else 'name' end as matched_on
    into v_dupe
    from qvm_new_apps.customers c
    join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
   where c.merged_into is null
     and ( (v_cr  is not null and lower(btrim(c.cr_number))  = lower(v_cr))
        or (v_vat is not null and lower(btrim(c.vat_number)) = lower(v_vat))
        or lower(btrim(ld.list_data)) = lower(v_name)
        or lower(btrim(coalesce(c.name_en,''))) = lower(v_name) )
   limit 1;

  if v_dupe.customer_id is not null then
    return jsonb_build_object('status', false, 'message', 'عميل مطابق موجود بالفعل',
      'data', jsonb_build_object('duplicate', true, 'matched_on', v_dupe.matched_on,
                                 'customer_id', v_dupe.customer_id, 'name', v_dupe.name,
                                 'source', v_dupe.source));
  end if;

  -- 1. the company row everything else keys on
  insert into qvm_new_apps.list_data (list_id, list_data)
  values (1, v_name)
  returning list_data_id into v_list_id;

  -- 2. the master
  insert into qvm_new_apps.customers (
    list_data_id, source, customer_code, name_ar, name_en, customer_type,
    cr_number, vat_number, contact_person, phone, email, region_id,
    needs_review, created_by)
  values (v_list_id, p_source, nullif(btrim(coalesce(p_customer_code,'')),''),
          nullif(btrim(coalesce(p_name_ar,'')),''), v_name, p_customer_type,
          v_cr, v_vat, nullif(btrim(coalesce(p_contact_person,'')),''),
          nullif(btrim(coalesce(p_phone,'')),''), nullif(btrim(coalesce(p_email,'')),''),
          p_region_id,
          -- An auto-created record always needs a human to finish it; a manual
          -- one without a branch cannot receive an order yet either.
          p_source = 'auto' or nullif(btrim(coalesce(p_branch_name,'')),'') is null,
          auth.uid())
  returning customer_id into v_cust;

  -- 3..6 only make sense once there is a branch
  if nullif(btrim(coalesce(p_branch_name,'')), '') is not null then
    if p_region_id is null then
      raise exception 'المنطقة مطلوبة مع الفرع، لأن تسلسل أرقام الطلبات مرتبط بها';
    end if;

    insert into qvm_new_apps.client_branches (list_data_id, branch_name, region_id, order_category, city)
    values (v_list_id, btrim(p_branch_name), p_region_id, p_order_category,
            nullif(btrim(coalesce(p_branch_city,'')),''))
    returning customer_id into v_branch;

    -- 4. the prefix — shared across branches of this company in this region
    select exists (select 1 from qvm_new_apps.order_number_sequences
                    where lists_data_id = v_list_id and region_id = p_region_id)
      into v_seq_exists;

    if not v_seq_exists then
      -- Derived from the name when the caller gives nothing, and kept unique so
      -- one company's numbering can never collide with another's.
      v_prefix := upper(regexp_replace(coalesce(nullif(btrim(coalesce(p_order_prefix,'')),''),
                                                left(regexp_replace(v_name, '[^A-Za-z]', '', 'g'), 3)),
                                       '[^A-Z0-9]', '', 'g'));
      if coalesce(v_prefix, '') = '' then v_prefix := 'C' || v_list_id::text; end if;
      while exists (select 1 from qvm_new_apps.order_number_sequences s where s.prefix = v_prefix) loop
        v_prefix := v_prefix || v_list_id::text;
      end loop;

      insert into qvm_new_apps.order_number_sequences (lists_data_id, region_id, sequence_name, prefix)
      values (v_list_id, p_region_id, lower(regexp_replace(v_name, '[^A-Za-z0-9]', '_', 'g')) || '_seq', v_prefix);
    end if;

    -- 5. the account manager — eleven functions read this table, and an order
    -- with no resolvable manager has nobody to land on.
    if p_account_manager is not null then
      insert into qvm_new_apps.account_manager_branches (customer_id, slot_number, main_account_manager)
      values (v_branch, 1, p_account_manager);
    end if;

    -- 6. the first address, default for this branch
    if nullif(btrim(coalesce(p_address_line,'')), '') is not null then
      insert into qvm_new_apps.customer_addresses (
        customer_id, client_branch_id, label, address_line, city, region_id,
        contact_name, contact_phone, is_default, created_by)
      values (v_cust, v_branch, coalesce(nullif(btrim(coalesce(p_address_label,'')),''), 'العنوان الرئيسي'),
              btrim(p_address_line), nullif(btrim(coalesce(p_branch_city,'')),''), p_region_id,
              nullif(btrim(coalesce(p_contact_person,'')),''),
              nullif(btrim(coalesce(p_contact_phone,'')),''), true, auth.uid())
      returning address_id into v_addr;
    end if;
  end if;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, after, changed_by)
  values (v_cust, 'customer', v_cust, 'create',
          jsonb_build_object('name', v_name, 'source', p_source, 'list_data_id', v_list_id,
                             'branch_id', v_branch, 'address_id', v_addr),
          auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('customer_id', v_cust, 'list_data_id', v_list_id,
                               'branch_id', v_branch, 'address_id', v_addr,
                               'can_receive_orders', v_branch is not null));
end
$function$;
-- qvm_new_apps.customer_document_save(p_customer_id bigint, p_file_path text, p_doc_type text, p_doc_number text, p_issued_on date, p_expires_on date)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_document_save(p_customer_id bigint, p_file_path text, p_doc_type text, p_doc_number text DEFAULT NULL::text, p_issued_on date DEFAULT NULL::date, p_expires_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_id bigint;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_file_path,'')), '') is null then
    return jsonb_build_object('status', false, 'message', 'الملف مطلوب', 'data', null);
  end if;
  if p_doc_type not in ('cr','vat','national_address','contract','iban_letter','other') then
    return jsonb_build_object('status', false, 'message', 'نوع المستند غير معروف', 'data', null);
  end if;
  if p_issued_on is not null and p_expires_on is not null and p_expires_on < p_issued_on then
    return jsonb_build_object('status', false, 'message', 'تاريخ الانتهاء قبل تاريخ الإصدار', 'data', null);
  end if;

  insert into qvm_new_apps.files (module_type, module_id, file_path, user_id,
                                  doc_type, doc_number, issued_on, expires_on)
  values ('customer', p_customer_id, btrim(p_file_path), auth.uid(),
          p_doc_type, nullif(btrim(coalesce(p_doc_number,'')),''), p_issued_on, p_expires_on)
  returning id into v_id;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, after, changed_by)
  values (p_customer_id, 'document', v_id, 'create',
          jsonb_build_object('doc_type', p_doc_type, 'expires_on', p_expires_on), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object('id', v_id));
end
$function$;
-- qvm_new_apps.customer_get(p_customer_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_get(p_customer_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select jsonb_build_object(
    'profile', to_jsonb(c) || jsonb_build_object('company_name', ld.list_data),

    -- Branches come from the existing table — linked, never copied.
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'branch_id', cb.customer_id, 'branch_name', cb.branch_name,
               'city', cb.city, 'region_id', cb.region_id,
               'order_category', cb.order_category,
               'address_count', (select count(*) from qvm_new_apps.customer_addresses a
                                  where a.client_branch_id = cb.customer_id and a.is_active),
               'account_managers', (select count(*) from qvm_new_apps.account_manager_branches amb
                                     where amb.customer_id = cb.customer_id),
               -- Without a prefix for this company+region an order cannot be numbered.
               'can_receive_orders', exists (
                  select 1 from qvm_new_apps.order_number_sequences s
                   where s.lists_data_id = cb.list_data_id and s.region_id = cb.region_id))
             order by cb.customer_id)
      from qvm_new_apps.client_branches cb where cb.list_data_id = c.list_data_id), '[]'::jsonb),

    'addresses', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.is_default desc, a.address_id)
      from qvm_new_apps.customer_addresses a
      where a.customer_id = c.customer_id and a.is_active), '[]'::jsonb),

    -- C-6 badges are computed here so every screen reads the same rule.
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'doc_type', f.doc_type, 'doc_number', f.doc_number,
               'issued_on', f.issued_on, 'expires_on', f.expires_on,
               'file_path', f.file_path, 'uploaded_by', f.user_id, 'uploaded_at', f.created_at,
               'state', case
                 when f.expires_on is null then 'no_expiry'
                 when f.expires_on < current_date then 'expired'
                 when f.expires_on <= current_date + 30 then 'expiring_soon'
                 else 'valid' end)
             order by f.created_at desc)
      from qvm_new_apps.files f
      where f.module_type = 'customer' and f.module_id = c.customer_id), '[]'::jsonb),

    -- C-7 reads this table; with approvals off it is simply empty.
    'approvers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', ub.user_id, 'user_name', u.user_name,
               'branch_id', ub.client_branch_id, 'is_approver', ub.is_approver)
             order by u.user_name)
      from qvm_new_apps.user_branches ub
      join qvm_new_apps.client_branches cb on cb.customer_id = ub.client_branch_id
      left join qvm_new_apps.user_data u on u.user_id = ub.user_id
      where cb.list_data_id = c.list_data_id), '[]'::jsonb),

    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', u.user_id, 'user_name', u.user_name, 'user_role', u.user_role,
               'default_branch', u.user_branch)
             order by u.user_name)
      from qvm_new_apps.user_data u where u.user_company = c.list_data_id), '[]'::jsonb),

    -- C-4: warning only, and honest about why there is no number yet —
    -- invoices carry no amounts until QNEW-124.
    'credit', jsonb_build_object(
      'limit', c.credit_limit,
      'terms_days', c.payment_terms_days,
      'on_hold', c.credit_hold,
      'outstanding', null,
      'over_limit', false,
      'unavailable_reason', 'invoice amounts are not stored yet (QNEW-124)')
  )
  into v
  from qvm_new_apps.customers c
  join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
  where c.customer_id = p_customer_id;

  if v is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end
$function$;
-- qvm_new_apps.customer_merge_into(p_customer_id bigint, p_name_ar text, p_name_en text, p_customer_type text, p_cr_number text, p_vat_number text, p_contact_person text, p_phone text, p_email text, p_region_id integer, p_customer_code text, p_branch_name text, p_branch_city text, p_order_category integer, p_account_manager uuid, p_order_prefix text, p_address_line text, p_address_label text, p_contact_phone text)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_merge_into(p_customer_id bigint, p_name_ar text DEFAULT NULL::text, p_name_en text DEFAULT NULL::text, p_customer_type text DEFAULT NULL::text, p_cr_number text DEFAULT NULL::text, p_vat_number text DEFAULT NULL::text, p_contact_person text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_region_id integer DEFAULT NULL::integer, p_customer_code text DEFAULT NULL::text, p_branch_name text DEFAULT NULL::text, p_branch_city text DEFAULT NULL::text, p_order_category integer DEFAULT NULL::integer, p_account_manager uuid DEFAULT NULL::uuid, p_order_prefix text DEFAULT NULL::text, p_address_line text DEFAULT NULL::text, p_address_label text DEFAULT NULL::text, p_contact_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_before  jsonb;
  v_after   jsonb;
  v_list_id integer;
  v_branch  bigint;
  v_addr    bigint;
  v_prefix  text;
  v_name    text;
  v_added   text[] := '{}';
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select to_jsonb(c), c.list_data_id into v_before, v_list_id
    from qvm_new_apps.customers c where c.customer_id = p_customer_id;
  if v_before is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  -- A record that was itself merged away is not a merge target; the one it
  -- points at is.
  if v_before->>'merged_into' is not null then
    return jsonb_build_object('status', false, 'message', 'هذا السجل مدموج بالفعل في عميل آخر', 'data', null);
  end if;

  update qvm_new_apps.customers c set
    name_ar        = coalesce(c.name_ar,        nullif(btrim(coalesce(p_name_ar, '')), '')),
    name_en        = coalesce(c.name_en,        nullif(btrim(coalesce(p_name_en, '')), '')),
    customer_type  = coalesce(c.customer_type,  nullif(btrim(coalesce(p_customer_type, '')), '')),
    cr_number      = coalesce(c.cr_number,      nullif(btrim(coalesce(p_cr_number, '')), '')),
    vat_number     = coalesce(c.vat_number,     nullif(btrim(coalesce(p_vat_number, '')), '')),
    contact_person = coalesce(c.contact_person, nullif(btrim(coalesce(p_contact_person, '')), '')),
    phone          = coalesce(c.phone,          nullif(btrim(coalesce(p_phone, '')), '')),
    email          = coalesce(c.email,          nullif(btrim(coalesce(p_email, '')), '')),
    region_id      = coalesce(c.region_id,      p_region_id),
    customer_code  = coalesce(c.customer_code,  nullif(btrim(coalesce(p_customer_code, '')), '')),
    updated_at     = now()
  where c.customer_id = p_customer_id;

  -- The branch is what an auto record is usually missing, and without one the
  -- customer cannot receive an order at all. Same name twice is the admin
  -- re-typing a branch that is already there, not a second location.
  if nullif(btrim(coalesce(p_branch_name, '')), '') is not null then
    select b.customer_id into v_branch
      from qvm_new_apps.client_branches b
     where b.list_data_id = v_list_id
       and lower(btrim(b.branch_name)) = lower(btrim(p_branch_name))
     limit 1;

    if v_branch is null then
      if coalesce(p_region_id, (v_before->>'region_id')::integer) is null then
        raise exception 'المنطقة مطلوبة مع الفرع، لأن تسلسل أرقام الطلبات مرتبط بها';
      end if;

      insert into qvm_new_apps.client_branches (list_data_id, branch_name, region_id, order_category, city)
      values (v_list_id, btrim(p_branch_name),
              coalesce(p_region_id, (v_before->>'region_id')::integer), p_order_category,
              nullif(btrim(coalesce(p_branch_city, '')), ''))
      returning customer_id into v_branch;
      v_added := v_added || 'branch'::text;

      if not exists (select 1 from qvm_new_apps.order_number_sequences
                      where lists_data_id = v_list_id
                        and region_id = coalesce(p_region_id, (v_before->>'region_id')::integer)) then
        v_name := coalesce(nullif(btrim(coalesce(p_name_en, '')), ''), v_before->>'name_en', 'C');
        v_prefix := upper(regexp_replace(coalesce(nullif(btrim(coalesce(p_order_prefix, '')), ''),
                                                  left(regexp_replace(v_name, '[^A-Za-z]', '', 'g'), 3)),
                                         '[^A-Z0-9]', '', 'g'));
        if coalesce(v_prefix, '') = '' then v_prefix := 'C' || v_list_id::text; end if;
        while exists (select 1 from qvm_new_apps.order_number_sequences s where s.prefix = v_prefix) loop
          v_prefix := v_prefix || v_list_id::text;
        end loop;

        insert into qvm_new_apps.order_number_sequences (lists_data_id, region_id, sequence_name, prefix)
        values (v_list_id, coalesce(p_region_id, (v_before->>'region_id')::integer),
                lower(regexp_replace(v_name, '[^A-Za-z0-9]', '_', 'g')) || '_seq', v_prefix);
        v_added := v_added || 'sequence'::text;
      end if;
    end if;

    if p_account_manager is not null
       and not exists (select 1 from qvm_new_apps.account_manager_branches a where a.customer_id = v_branch) then
      insert into qvm_new_apps.account_manager_branches (customer_id, slot_number, main_account_manager)
      values (v_branch, 1, p_account_manager);
      v_added := v_added || 'account_manager'::text;
    end if;

    if nullif(btrim(coalesce(p_address_line, '')), '') is not null
       and not exists (select 1 from qvm_new_apps.customer_addresses a
                        where a.customer_id = p_customer_id
                          and lower(btrim(a.address_line)) = lower(btrim(p_address_line))) then
      insert into qvm_new_apps.customer_addresses (
        customer_id, client_branch_id, label, address_line, city, region_id,
        contact_name, contact_phone, is_default, created_by)
      values (p_customer_id, v_branch,
              coalesce(nullif(btrim(coalesce(p_address_label, '')), ''), 'العنوان الرئيسي'),
              btrim(p_address_line), nullif(btrim(coalesce(p_branch_city, '')), ''),
              coalesce(p_region_id, (v_before->>'region_id')::integer),
              nullif(btrim(coalesce(p_contact_person, '')), ''),
              nullif(btrim(coalesce(p_contact_phone, '')), ''),
              -- Default only if this customer has no default yet.
              not exists (select 1 from qvm_new_apps.customer_addresses d
                           where d.customer_id = p_customer_id and d.is_default and d.is_active),
              auth.uid())
      returning address_id into v_addr;
      v_added := v_added || 'address'::text;
    end if;
  end if;

  -- «يحتاج مراجعة» was the flag saying a human had not finished this record.
  -- A merge is that human, provided the record can now take an order.
  update qvm_new_apps.customers c set needs_review = false, updated_at = now()
   where c.customer_id = p_customer_id
     and exists (select 1 from qvm_new_apps.client_branches b where b.list_data_id = v_list_id);

  select to_jsonb(c) into v_after from qvm_new_apps.customers c where c.customer_id = p_customer_id;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, before, after, changed_by)
  values (p_customer_id, 'customer', p_customer_id, 'merge', v_before, v_after, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('customer_id', p_customer_id, 'branch_id', v_branch,
                               'address_id', v_addr, 'added', to_jsonb(v_added),
                               'can_receive_orders',
                               exists (select 1 from qvm_new_apps.client_branches b
                                        where b.list_data_id = v_list_id)));
end
$function$;
-- qvm_new_apps.customer_update(p_customer_id bigint, p_patch jsonb)
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_update(p_customer_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_before jsonb; v_after jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select to_jsonb(c) into v_before from qvm_new_apps.customers c where c.customer_id = p_customer_id;
  if v_before is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  -- Only these may be set from the screen. Anything else in the patch is
  -- ignored rather than trusted — source and merged_into are not editable.
  update qvm_new_apps.customers c set
    -- The code is the one field a blank never clears: orders and sequences
    -- are read by it, so an empty box means "unchanged", not "remove it".
    customer_code      = coalesce(nullif(btrim(p_patch->>'customer_code'), ''), c.customer_code),
    name_ar            = case when p_patch ? 'name_ar'        then nullif(btrim(p_patch->>'name_ar'), '')        else c.name_ar end,
    name_en            = case when p_patch ? 'name_en'        then nullif(btrim(p_patch->>'name_en'), '')        else c.name_en end,
    customer_type      = case when p_patch ? 'customer_type'  then nullif(btrim(p_patch->>'customer_type'), '')  else c.customer_type end,
    cr_number          = case when p_patch ? 'cr_number'      then nullif(btrim(p_patch->>'cr_number'), '')      else c.cr_number end,
    vat_number         = case when p_patch ? 'vat_number'     then nullif(btrim(p_patch->>'vat_number'), '')     else c.vat_number end,
    contact_person     = case when p_patch ? 'contact_person' then nullif(btrim(p_patch->>'contact_person'), '') else c.contact_person end,
    phone              = case when p_patch ? 'phone'          then nullif(btrim(p_patch->>'phone'), '')          else c.phone end,
    email              = case when p_patch ? 'email'          then nullif(btrim(p_patch->>'email'), '')          else c.email end,
    region_id          = case when p_patch ? 'region_id'          then nullif(btrim(p_patch->>'region_id'), '')::integer          else c.region_id end,
    payment_terms_days = case when p_patch ? 'payment_terms_days' then nullif(btrim(p_patch->>'payment_terms_days'), '')::integer else c.payment_terms_days end,
    credit_limit       = case when p_patch ? 'credit_limit'       then nullif(btrim(p_patch->>'credit_limit'), '')::numeric       else c.credit_limit end,
    payment_method_note= case when p_patch ? 'payment_method_note' then nullif(btrim(p_patch->>'payment_method_note'), '')        else c.payment_method_note end,
    -- The flags have no "unset" state, so a null in the patch keeps the flag.
    credit_hold        = coalesce((p_patch->>'credit_hold')::boolean, c.credit_hold),
    is_active          = coalesce((p_patch->>'is_active')::boolean, c.is_active),
    needs_review       = coalesce((p_patch->>'needs_review')::boolean, c.needs_review),
    approvals_enabled  = coalesce((p_patch->>'approvals_enabled')::boolean, c.approvals_enabled),
    updated_at         = now()
  where c.customer_id = p_customer_id
  returning to_jsonb(c) into v_after;

  insert into qvm_new_apps.customer_log (customer_id, entity, entity_id, action, before, after, changed_by)
  values (p_customer_id,
          case when p_patch ? 'payment_terms_days' or p_patch ? 'credit_limit' or p_patch ? 'credit_hold'
               then 'terms' else 'customer' end,
          p_customer_id, 'update', v_before, v_after, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok', 'data', v_after);
end
$function$;
-- qvm_new_apps.customers_list(p_search text, p_source text, p_region_id integer, p_status text, p_account_manager uuid, p_limit integer, p_offset integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.customers_list(p_search text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_region_id integer DEFAULT NULL::integer, p_status text DEFAULT NULL::text, p_account_manager uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_rows jsonb; v_total bigint; v_counters jsonb;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with base as (
    select c.customer_id, c.customer_code, c.list_data_id, c.source,
           c.name_ar, c.name_en, c.customer_type, c.cr_number, c.vat_number,
           c.contact_person, c.phone, c.email, c.region_id,
           c.payment_terms_days, c.credit_limit, c.credit_hold,
           c.approvals_enabled, c.is_active, c.needs_review, c.created_at,
           ld.list_data as company_name,
           -- The branch count is what tells an admin whether this customer can
           -- actually receive an order at all.
           (select count(*) from qvm_new_apps.client_branches cb
             where cb.list_data_id = c.list_data_id) as branch_count,
           (select count(*) from qvm_new_apps.customer_addresses a
             where a.customer_id = c.customer_id and a.is_active) as address_count,
           -- Documents already past their expiry date (C-6 badge).
           (select count(*) from qvm_new_apps.files f
             where f.module_type = 'customer' and f.module_id = c.customer_id
               and f.expires_on is not null and f.expires_on < current_date) as expired_documents
      from qvm_new_apps.customers c
      join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
     where c.merged_into is null
       and (p_source is null or c.source = p_source)
       and (p_region_id is null or c.region_id = p_region_id)
       and (p_status is null
            or (p_status = 'active'   and c.is_active and not c.needs_review)
            or (p_status = 'inactive' and not c.is_active)
            or (p_status = 'review'   and c.needs_review))
       -- An account manager is attached to a branch, not to the company, so the
       -- filter asks whether they manage any branch of this customer.
       and (p_account_manager is null or exists (
             select 1 from qvm_new_apps.account_manager_branches amb
               join qvm_new_apps.client_branches cb on cb.customer_id = amb.customer_id
              where cb.list_data_id = c.list_data_id
                and p_account_manager in (amb.main_account_manager, amb.first_substitute,
                                          amb.second_substitute, amb.fallback_account_manager)))
       and (v_q is null
            or ld.list_data   ilike '%'||v_q||'%'
            or c.name_ar      ilike '%'||v_q||'%'
            or c.name_en      ilike '%'||v_q||'%'
            or c.customer_code ilike '%'||v_q||'%'
            or c.cr_number    ilike '%'||v_q||'%'
            or c.vat_number   ilike '%'||v_q||'%')
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.needs_review desc, x.company_name), '[]'::jsonb),
         (select count(*) from base)
    into v_rows, v_total
    from (select * from base
           order by needs_review desc, company_name
           limit greatest(coalesce(p_limit, 50), 1)
          offset greatest(coalesce(p_offset, 0), 0)) x;

  -- Counters per source, as the AC asks, plus the status counts the card shows.
  select jsonb_build_object(
           'all',      count(*),
           'database', count(*) filter (where source = 'database'),
           'manual',   count(*) filter (where source = 'manual'),
           'auto',     count(*) filter (where source = 'auto'),
           'active',   count(*) filter (where is_active and not needs_review),
           'inactive', count(*) filter (where not is_active),
           'review',   count(*) filter (where needs_review))
    into v_counters
    from qvm_new_apps.customers where merged_into is null;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('customers', v_rows, 'total', v_total, 'counters', v_counters));
end
$function$;
-- qvm_new_apps.email_accounts_for_sync()
CREATE OR REPLACE FUNCTION qvm_new_apps.email_accounts_for_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v
  from (
    select a.account_id, a.email_address, a.imap_host, a.imap_port,
           a.smtp_host, a.smtp_port, a.last_uid, a.uid_validity,
           a.vendors_only, a.status, s.decrypted_secret as app_password
    from qvm_new_apps.email_accounts a
    join vault.decrypted_secrets s on s.id = a.secret_id
    where a.status <> 'disconnected'
  ) x;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end
$function$;
-- qvm_new_apps.email_connect_account(p_email text, p_app_password text, p_display_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.email_connect_account(p_email text, p_app_password text, p_display_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_email  text := lower(btrim(p_email));
  v_pass   text := regexp_replace(coalesce(p_app_password,''), '\s', '', 'g');
  v_secret uuid;
  v_id     bigint;
  v_owner  uuid;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('status', false, 'message', 'invalid email address', 'data', null);
  end if;
  -- Google shows the app password as four groups of four; people paste it with
  -- the spaces, and rejecting that would look like a wrong password.
  if length(v_pass) <> 16 then
    return jsonb_build_object('status', false,
      'message', 'app password must be the 16 characters Google shows you', 'data', null);
  end if;

  select user_id into v_owner from qvm_new_apps.email_accounts where email_address = v_email;
  if v_owner is not null and v_owner <> auth.uid() then
    return jsonb_build_object('status', false,
      'message', 'that mailbox is already linked by someone else', 'data', null);
  end if;

  v_secret := vault.create_secret(v_pass, 'email_app_password:' || v_email,
                                  'Gmail app password for the shared inbox');

  insert into qvm_new_apps.email_accounts (user_id, email_address, secret_id, display_name, status)
  values (auth.uid(), v_email, v_secret, nullif(btrim(coalesce(p_display_name,'')), ''), 'connecting')
  on conflict (email_address) do update
    set secret_id    = excluded.secret_id,
        display_name = coalesce(excluded.display_name, qvm_new_apps.email_accounts.display_name),
        status       = 'connecting',
        last_error   = null,
        updated_at   = now()
  returning account_id into v_id;

  -- Wake the bridge immediately instead of waiting for its next sweep, so the
  -- screen can say "connected" while the person is still looking at it.
  perform pg_notify('email_accounts', v_id::text);

  return jsonb_build_object('status', true, 'message', 'ok',
                            'data', jsonb_build_object('account_id', v_id));
end
$function$;
-- qvm_new_apps.email_conversation_key(p_subject text)
CREATE OR REPLACE FUNCTION qvm_new_apps.email_conversation_key(p_subject text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select nullif(
    regexp_replace(
      regexp_replace(lower(btrim(coalesce(p_subject, ''))),
                     '^((re|fwd|fw|رد|إعادة توجيه)\s*(\[[0-9]+\])?\s*:\s*)+', '', 'gi'),
      '\s+', ' ', 'g'),
    '');
$function$;
-- qvm_new_apps.email_disconnect_account(p_account_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.email_disconnect_account(p_account_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_secret uuid; v_owner uuid;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select secret_id, user_id into v_secret, v_owner
    from qvm_new_apps.email_accounts where account_id = p_account_id;
  if v_secret is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  -- Conversations survive unlinking: the correspondence is company history, not
  -- the employee's, and deleting it with the mailbox would lose the record.
  update qvm_new_apps.email_accounts set status = 'disconnected', updated_at = now()
   where account_id = p_account_id;
  delete from vault.secrets where id = v_secret;

  perform pg_notify('email_accounts', p_account_id::text);
  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;
-- qvm_new_apps.email_ingest_message(p_account_id bigint, p_message_id text, p_from_email text, p_from_name text, p_subject text, p_body text, p_direction text, p_in_reply_to text, p_sent_at timestamp with time zone, p_headers jsonb, p_raw jsonb, p_has_attachments boolean, p_media_url text, p_media_mime text, p_media_kind text, p_media_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.email_ingest_message(p_account_id bigint, p_message_id text, p_from_email text, p_from_name text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_body text DEFAULT NULL::text, p_direction text DEFAULT 'in'::text, p_in_reply_to text DEFAULT NULL::text, p_sent_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_headers jsonb DEFAULT NULL::jsonb, p_raw jsonb DEFAULT NULL::jsonb, p_has_attachments boolean DEFAULT false, p_media_url text DEFAULT NULL::text, p_media_mime text DEFAULT NULL::text, p_media_kind text DEFAULT NULL::text, p_media_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_contact bigint; v_thread bigint; v_msg bigint;
  v_addr    text := lower(btrim(coalesce(p_from_email,'')));
  v_at      timestamptz := coalesce(p_sent_at, now());
  v_dir     text := case when p_direction = 'out' then 'out' else 'in' end;
  v_preview text; v_reply_local bigint; v_acct record;
  v_media   text := nullif(btrim(coalesce(p_media_url,'')),'');
  v_kind    text := nullif(btrim(coalesce(p_media_kind,'')),'');
  v_html    text := nullif(btrim(coalesce(p_headers->>'html_path','')),'');
  v_key     text;
  v_subject text := nullif(btrim(coalesce(p_subject,'')),'');
begin
  if v_addr = '' or nullif(btrim(coalesce(p_message_id,'')),'') is null then
    return jsonb_build_object('status', false, 'message', 'sender and message id required', 'data', null);
  end if;

  select account_id, email_address, vendors_only into v_acct
    from qvm_new_apps.email_accounts where account_id = p_account_id and status <> 'disconnected';
  if v_acct.account_id is null then
    return jsonb_build_object('status', false, 'message', 'unknown or disconnected mailbox', 'data', null);
  end if;

  if v_dir = 'in' and v_addr = lower(v_acct.email_address) then
    return jsonb_build_object('status', true, 'message', 'self', 'data', jsonb_build_object('skipped', true));
  end if;

  if coalesce(v_acct.vendors_only, false)
     and not exists (select 1 from qvm_new_apps.vendors v where lower(v.email) = v_addr) then
    return jsonb_build_object('status', true, 'message', 'filtered', 'data', jsonb_build_object('skipped', true));
  end if;

  if v_media is not null and v_kind is null then
    v_kind := case
      when p_media_mime like 'image/%' then 'image'
      when p_media_mime like 'video/%' then 'video'
      when p_media_mime like 'audio/%' then 'audio'
      else 'document' end;
  end if;

  -- One contact per correspondent, so the vendor link and the requests panel
  -- stay attached to the person rather than to one of their conversations.
  insert into qvm_new_apps.wa_contacts (email, email_account_id, display_name, chat_type)
  values (v_addr, p_account_id, nullif(btrim(coalesce(p_from_name,'')),''), 'individual')
  on conflict (lower(email), email_account_id) where email is not null do update
    set display_name = coalesce(qvm_new_apps.wa_contacts.display_name, excluded.display_name)
  returning wa_contact_id into v_contact;

  update qvm_new_apps.wa_contacts c set vendor_id = v.vendor_id
    from (select vendor_id from qvm_new_apps.vendors
           where lower(email) = v_addr and email is not null limit 1) v
   where c.wa_contact_id = v_contact and c.vendor_id is null;

  if nullif(btrim(coalesce(p_in_reply_to,'')),'') is not null then
    select message_id into v_reply_local
      from qvm_new_apps.wa_messages where wa_message_id = btrim(p_in_reply_to) limit 1;
  end if;

  -- Rule 1: follow the reply chain.
  if v_reply_local is not null then
    select thread_id into v_thread from qvm_new_apps.wa_messages where message_id = v_reply_local;
  end if;

  -- Rule 2: fall back to the subject.
  if v_thread is null then
    v_key := coalesce(qvm_new_apps.email_conversation_key(v_subject), btrim(p_message_id));

    insert into qvm_new_apps.wa_threads (wa_contact_id, channel, email_account_id, subject, email_conversation_key)
    values (v_contact, 'email', p_account_id, v_subject, v_key)
    on conflict (wa_contact_id, email_conversation_key) where channel = 'email'
      do update set subject = coalesce(qvm_new_apps.wa_threads.subject, excluded.subject)
    returning thread_id into v_thread;
  end if;

  perform qvm_new_apps.wa_revive_thread(v_thread);

  insert into qvm_new_apps.wa_messages (
    thread_id, wa_message_id, direction, body, sender_name, sender_jid,
    wa_timestamp, delivery_status, raw, email_headers, email_html_path,
    reply_to_wa_id, reply_to_message_id,
    media_url, media_mime, media_kind, media_name)
  values (v_thread, btrim(p_message_id), v_dir, p_body,
          nullif(btrim(coalesce(p_from_name,'')),''), v_addr, v_at,
          case when v_dir = 'in' then 'received' else 'sent' end,
          p_raw, p_headers, v_html,
          nullif(btrim(coalesce(p_in_reply_to,'')),''), v_reply_local,
          v_media, nullif(btrim(coalesce(p_media_mime,'')),''), v_kind,
          nullif(btrim(coalesce(p_media_name,'')),''))
  on conflict (wa_message_id) where wa_message_id is not null do nothing
  returning message_id into v_msg;

  if v_msg is null then
    return jsonb_build_object('status', true, 'message', 'duplicate',
      'data', jsonb_build_object('duplicate', true, 'thread_id', v_thread, 'contact_id', v_contact));
  end if;

  v_preview := coalesce(nullif(btrim(coalesce(p_body,'')),''),
                        v_subject,
                        case v_kind
                          when 'image' then '📷 صورة' when 'video' then '🎥 فيديو'
                          when 'audio' then '🎵 مقطع صوتي'
                          else case when v_media is not null or p_has_attachments
                                    then '📎 مرفق' else '' end end);

  update qvm_new_apps.wa_threads
     set last_message_at = greatest(coalesce(last_message_at, to_timestamp(0)), v_at),
         last_inbound_at = case when v_dir = 'in'
                                then greatest(coalesce(last_inbound_at, to_timestamp(0)), v_at)
                                else last_inbound_at end,
         last_message_preview = left(v_preview, 160),
         unread_count = case when v_dir = 'in' then unread_count + 1 else unread_count end,
         status = case when status = 'closed' and v_dir = 'in' then 'open' else status end
   where thread_id = v_thread;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('duplicate', false, 'thread_id', v_thread,
                               'contact_id', v_contact, 'message_id', v_msg));
end
$function$;
-- qvm_new_apps.email_list_accounts()
CREATE OR REPLACE FUNCTION qvm_new_apps.email_list_accounts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v jsonb;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb) into v
  from (
    select a.account_id, a.email_address, a.display_name, a.status, a.last_error,
           a.last_synced_at, a.vendors_only, a.created_at,
           a.user_id = auth.uid() as is_mine,
           (select count(*) from qvm_new_apps.wa_threads t
             where t.email_account_id = a.account_id and t.deleted_at is null) as thread_count
    from qvm_new_apps.email_accounts a
  ) x;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end
$function$;
-- qvm_new_apps.email_set_account_state(p_account_id bigint, p_status text, p_error text, p_last_uid bigint, p_uid_validity bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.email_set_account_state(p_account_id bigint, p_status text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_last_uid bigint DEFAULT NULL::bigint, p_uid_validity bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  update qvm_new_apps.email_accounts
     set status       = coalesce(p_status, status),
         -- An explicit empty string clears a stale error; null leaves it alone.
         last_error   = case when p_error = '' then null
                             when p_error is not null then left(p_error, 500)
                             else last_error end,
         last_uid     = coalesce(p_last_uid, last_uid),
         uid_validity = coalesce(p_uid_validity, uid_validity),
         last_synced_at = case when p_status = 'connected' then now() else last_synced_at end,
         updated_at   = now()
   where account_id = p_account_id;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;
-- qvm_new_apps.get_extract_pn_order(p_quotation_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.get_extract_pn_order(p_quotation_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_order jsonb; v_parts jsonb;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;

  select to_jsonb(o) into v_order from (
    select q.quotation_id, q.order_number, q.plate_number, q.created_at as rfq_date,
           coalesce(bmain.list_data,'') as brand, coalesce(f.model,'') as model,
           coalesce(f.year::text,'') as year, coalesce(f.vin,'') as vin,
           coalesce(cb.branch_name,'') as branch_name, coalesce(ldc.list_data,'') as client_name,
           coalesce(am.user_name,'') as manager,
           greatest(0, (extract(epoch from (now() - q.created_at)) / 60)::int) as waiting_minutes,
           q.extract_locked_by,
           (q.extract_locked_by is not null and coalesce(q.extract_lock_touched_at, q.extract_locked_at) > now() - interval '30 minutes') as lock_live,
           (select ud.user_name from qvm_new_apps.user_data ud where ud.user_id = q.extract_locked_by) as locked_by_name,
           (q.extract_locked_by = v_uid) as locked_by_me,
           (select count(*) from qvm_new_apps.quotation_items u
             where u.quotation_id = q.quotation_id and u.extraction_status = 'unclear')::int as unclear_count
    from qvm_new_apps.quotations q
    left join lateral (
      select qi2.model, qi2.year, qi2.vin, qi2.main_brand, qi2.customer_id
      from qvm_new_apps.quotation_items qi2 where qi2.quotation_id = q.quotation_id
      order by qi2.quotation_item_id limit 1
    ) f on true
    left join qvm_new_apps.list_data bmain on bmain.list_data_id = f.main_brand
    left join qvm_new_apps.client_branches cb on cb.customer_id = f.customer_id
    left join qvm_new_apps.list_data ldc on ldc.list_data_id = cb.list_data_id
    left join qvm_new_apps.user_data am on am.user_id = q.account_manager
    where q.quotation_id = p_quotation_id
  ) o;

  if v_order is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_id'); end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.added_at_extraction desc nulls last,
                                                p.quotation_item_id desc), '[]'::jsonb)
    into v_parts from (
    select qi.quotation_item_id, coalesce(qi.part_description,'') as part_description,
           coalesce(qi.part_number,'') as part_number,
           coalesce(qi.draft_part_number,'') as draft_part_number,
           qi.pn_state, qi.quantity,
           qi.extraction_status, qi.extraction_unclear_reason,
           coalesce((select ud.user_name from qvm_new_apps.user_data ud
                      where ud.user_id = qi.extraction_flagged_by), '') as unclear_by,
           coalesce(qi.added_at_extraction, false) as added_at_extraction,
           (coalesce(qi.added_at_extraction, false) and qi.created_by = v_uid) as can_remove,
           coalesce((select jsonb_agg(a.alt_part_number order by a.alt_pn_id)
                     from qvm_new_apps.quotation_item_alt_pns a
                     where a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alt_pns
    from qvm_new_apps.quotation_items qi
    where qi.quotation_id = p_quotation_id and qi.item_status = any (array[235, 236])
  ) p;

  return jsonb_build_object('status', true, 'message', 'OK',
    'data', jsonb_build_object('order', v_order, 'parts', v_parts));
end $function$;
-- qvm_new_apps.get_extract_pn_queue()
CREATE OR REPLACE FUNCTION qvm_new_apps.get_extract_pn_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_rows jsonb; v_orders int; v_parts int;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', null);
  end if;

  with pending as (
    -- an order qualifies while it still has at least one part with no PN saved to the order
    select qi.quotation_id
    from qvm_new_apps.quotation_items qi
    where qi.pn_state <> 'saved'
      and qi.item_status = any (array[235, 236])
    group by qi.quotation_id
  ),
  agg as (
    select q.quotation_id,
           q.order_number,
           q.plate_number,
           q.created_at                                             as rfq_date,
           coalesce(bmain.list_data, '')                            as brand,
           coalesce(qi_first.model, '')                             as model,
           coalesce(qi_first.year::text, '')                        as year,
           coalesce(qi_first.vin, '')                               as vin,
           coalesce(cb.branch_name, '')                             as branch_name,
           coalesce(ld_client.list_data, '')                        as client_name,
           coalesce(am.user_name, '')                               as manager,
           count(*)                                                 as total_parts,
           count(*) filter (where qi.pn_state = 'saved')             as saved_parts,
           count(*) filter (where qi.pn_state <> 'saved')            as pending_parts,
           floor(extract(epoch from (now() - q.created_at)) / 60)::int as waiting_minutes,
           q.extract_locked_by,
           q.extract_lock_touched_at,
           (q.extract_locked_by is not null
             and coalesce(q.extract_lock_touched_at, q.extract_locked_at) > now() - interval '30 minutes') as lock_live
    from pending p
    join qvm_new_apps.quotations q       on q.quotation_id = p.quotation_id
    join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
                                        and qi.item_status = any (array[235, 236])
    left join lateral (
      select qi2.model, qi2.year, qi2.vin, qi2.main_brand, qi2.customer_id
      from qvm_new_apps.quotation_items qi2
      where qi2.quotation_id = q.quotation_id
      order by qi2.quotation_item_id
      limit 1
    ) qi_first on true
    left join qvm_new_apps.list_data bmain      on bmain.list_data_id = qi_first.main_brand
    left join qvm_new_apps.client_branches cb   on cb.customer_id = qi_first.customer_id
    left join qvm_new_apps.list_data ld_client  on ld_client.list_data_id = cb.list_data_id
    left join qvm_new_apps.user_data am         on am.user_id = q.account_manager
    group by q.quotation_id, q.order_number, q.plate_number, q.created_at, bmain.list_data,
             qi_first.model, qi_first.year, qi_first.vin, cb.branch_name, ld_client.list_data,
             am.user_name, q.extract_locked_by, q.extract_lock_touched_at, q.extract_locked_at
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.waiting_minutes desc), '[]'::jsonb),
         count(*)::int, coalesce(sum(r.pending_parts), 0)::int
  into v_rows, v_orders, v_parts
  from (
    select a.*,
           case when a.lock_live then (select ud.user_name from qvm_new_apps.user_data ud where ud.user_id = a.extract_locked_by) end as locked_by_name,
           (a.lock_live and a.extract_locked_by = v_uid) as locked_by_me,
           case when a.lock_live then floor(extract(epoch from (now() - a.extract_lock_touched_at)) / 60)::int end as locked_minutes
    from agg a
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'orders', v_rows, 'total_orders', v_orders, 'total_pending_parts', v_parts
  ));
end $function$;
-- qvm_new_apps.get_orders_pricing_progress(p_quotation_ids integer[])
CREATE OR REPLACE FUNCTION qvm_new_apps.get_orders_pricing_progress(p_quotation_ids integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) into v_rows
  from (
    select qi.quotation_id,
           count(*) filter (where qi.item_status = 237)                            as sent_count,
           count(*) filter (where qi.item_status = 237 and vp.priced)              as priced_count
    from qvm_new_apps.quotation_items qi
    left join lateral (
      select true as priced
      from qvm_new_apps.quotation_vendor_items qvi
      where qvi.quotation_item_id = qi.quotation_item_id
        and (qvi.cost is not null and qvi.cost > 0)
      limit 1
    ) vp on true
    where qi.quotation_id = any(p_quotation_ids)
    group by qi.quotation_id
    having count(*) filter (where qi.item_status = 237) > 0
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', v_rows);
end $function$;
-- qvm_new_apps.get_vendor_quotation_extras_by_token(p_token uuid)
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_extras_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_quotation_id integer;
  v_quotation_vendor_id bigint;
  v_vendor_id bigint;
  v_expires_at timestamptz;
begin
  select qv.quotation_id, qv.quotation_vendor_id, qv.vendor_id, qv.token_expires_at
    into v_quotation_id, v_quotation_vendor_id, v_vendor_id, v_expires_at
    from qvm_new_apps.quotation_vendors qv
   where qv.access_token = p_token;

  -- Same two answers the detail loader gives, so the page can treat them alike.
  if v_quotation_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if now() > v_expires_at then
    return jsonb_build_object('status', 'expired');
  end if;

  return jsonb_build_object(
    'status', 'ok',

    -- Only this vendor's own rows on this quotation. Another vendor's part
    -- numbers on the same quotation are not theirs to see.
    'vendor_part_numbers', coalesce((
      select jsonb_object_agg(x.cost_id::text, x.vendor_part_number)
        from qvm_new_apps.quotation_vendor_items x
       where x.quotation_vendor_id = v_quotation_vendor_id
         and x.vendor_part_number is not null
         and btrim(x.vendor_part_number) <> ''), '{}'::jsonb),

    -- Keyed by item id, for the lines of this quotation only.
    'item_years', coalesce((
      select jsonb_object_agg(i.quotation_item_id::text, i.year)
        from qvm_new_apps.quotation_items i
       where i.quotation_id = v_quotation_id
         and i.year is not null and btrim(i.year::text) <> ''), '{}'::jsonb),

    -- A reference list, not anyone's data — the same rows get_brand_classes
    -- returns, minus the login it insists on.
    'brand_classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'brand_class_id', ld.list_data_id,
               'brand_class_name', ld.list_data) order by ld.list_data_id)
        from qvm_new_apps.list_data ld
        join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'brand_class'), '[]'::jsonb),

    -- This vendor's own files on this quotation, whoever uploaded them. Scoped by vendor_id, so
    -- another vendor's quote on the same order is never returned, and neither are the team's
    -- internal order-level files (which carry no vendor_id).
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attachment_id', a.attachment_id,
               'quotation_id',  a.quotation_id,
               'vendor_id',     a.vendor_id,
               'quotation_vendor_id', a.quotation_vendor_id,
               'file_url',      a.file_url,
               'file_path',     a.file_path,
               'file_name',     a.file_name,
               'file_type',     a.file_type,
               'mime_type',     a.mime_type,
               'file_size',     a.file_size,
               'ai_extracted',  a.ai_extracted,
               'created_at',    a.created_at,
               'created_by',    a.created_by) order by a.created_at desc)
        from qvm_new_apps.quotation_attachments a
       where a.quotation_id = v_quotation_id
         and a.vendor_id is not null
         and a.vendor_id = v_vendor_id), '[]'::jsonb)
  );
end
$function$;
-- qvm_new_apps.is_qparts_team()
CREATE OR REPLACE FUNCTION qvm_new_apps.is_qparts_team()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  select exists (
    select 1 from qvm_new_apps.user_data u
     where u.user_id = auth.uid()
       and (u.user_role in (172, 173, 269) or u.user_type = 185)
  );
$function$;
-- qvm_new_apps.lock_extract_order(p_quotation_id integer, p_action text)
CREATE OR REPLACE FUNCTION qvm_new_apps.lock_extract_order(p_quotation_id integer, p_action text DEFAULT 'lock'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_owner uuid; v_touched timestamptz; v_live boolean;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated');
  end if;

  select extract_locked_by, coalesce(extract_lock_touched_at, extract_locked_at)
    into v_owner, v_touched
  from qvm_new_apps.quotations where quotation_id = p_quotation_id for update;

  if not found then
    return jsonb_build_object('status', false, 'message', 'Invalid quotation_id');
  end if;

  v_live := v_owner is not null and v_touched > now() - interval '30 minutes';

  if p_action = 'release' then
    if v_live and v_owner <> v_uid then
      return jsonb_build_object('status', false, 'message', 'Locked by another user');
    end if;
    update qvm_new_apps.quotations
      set extract_locked_by = null, extract_locked_at = null, extract_lock_touched_at = null
      where quotation_id = p_quotation_id;
    return jsonb_build_object('status', true, 'message', 'released');
  end if;

  -- lock / touch
  if v_live and v_owner <> v_uid then
    return jsonb_build_object('status', false, 'message', 'Locked by another user',
      'locked_by', (select user_name from qvm_new_apps.user_data where user_id = v_owner));
  end if;

  update qvm_new_apps.quotations
    set extract_locked_by = v_uid,
        extract_locked_at = case when v_live and v_owner = v_uid then extract_locked_at else now() end,
        extract_lock_touched_at = now()
    where quotation_id = p_quotation_id;

  return jsonb_build_object('status', true, 'message', 'locked');
end $function$;
-- qvm_new_apps.may_touch_upload_batch(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.may_touch_upload_batch(p_batch_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  select qvm_new_apps.is_qparts_team()
      or exists (select 1 from qvm_new_apps.upload_batches b
                  where b.batch_id = p_batch_id
                    and b.source_kind = 'vendor'
                    and b.source_id = qvm_new_apps.current_upload_vendor_id());
$function$;
-- qvm_new_apps.normalize_part_number(p_value text)
CREATE OR REPLACE FUNCTION qvm_new_apps.normalize_part_number(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select nullif(upper(regexp_replace(coalesce(p_value, ''), '[^A-Za-z0-9]', '', 'g')), '');
$function$;
-- qvm_new_apps.notification_signal()
CREATE OR REPLACE FUNCTION qvm_new_apps.notification_signal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  perform qvm_new_apps.wa_signal('user:' || new.user_id::text || ':notify', 'changed');
  return null;
end
$function$;
-- qvm_new_apps.part_name_dictionary_refresh()
CREATE OR REPLACE FUNCTION qvm_new_apps.part_name_dictionary_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_rows integer;
begin
  with named as (
    select
      qvm_new_apps.normalize_part_number(qi.part_number) as clean_part_number,
      btrim(qi.part_description)                          as name,
      row_number() over (
        partition by qvm_new_apps.normalize_part_number(qi.part_number)
        order by qi.updated_at desc nulls last, qi.quotation_item_id desc
      ) as rn
    from qvm_new_apps.quotation_items qi
    where qi.part_number is not null
      and qvm_new_apps.normalize_part_number(qi.part_number) is not null
      and qi.part_description is not null
      and btrim(qi.part_description) <> ''
  )
  insert into qvm_new_apps.part_name_dictionary (clean_part_number, name, source, updated_at)
  select clean_part_number, name, 'quotation_history', now()
    from named where rn = 1
  on conflict (clean_part_number) do update
    set name = excluded.name, source = excluded.source, updated_at = now()
    -- A name that has not actually changed should not bump updated_at.
    where qvm_new_apps.part_name_dictionary.name is distinct from excluded.name;

  get diagnostics v_rows = row_count;
  return jsonb_build_object(
    'status', true,
    'message', 'Part-name dictionary refreshed',
    'changed', v_rows,
    'total', (select count(*) from qvm_new_apps.part_name_dictionary));
end
$function$;
-- qvm_new_apps.pricing_layer2_save(p_patch jsonb)
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_layer2_save(p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_row jsonb; v_kept bigint[] := '{}'; v_rid bigint; v_before jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select jsonb_build_object(
    'settings',  (select to_jsonb(s) from qvm_new_apps.pricing_settings s where s.id = 1),
    'modifiers', (select jsonb_agg(to_jsonb(m)) from qvm_new_apps.pricing_modifiers m),
    'routes',    (select jsonb_agg(to_jsonb(r)) from qvm_new_apps.pricing_route_modifiers r))
    into v_before;

  if p_patch ? 'modifiers' then
    for v_row in select * from jsonb_array_elements(p_patch->'modifiers') loop
      update qvm_new_apps.pricing_modifiers m set
        percent    = coalesce((v_row->>'percent')::numeric, m.percent),
        is_enabled = coalesce((v_row->>'is_enabled')::boolean, m.is_enabled),
        updated_by = auth.uid(), updated_at = now()
      where m.modifier_key = v_row->>'modifier_key';
    end loop;
  end if;

  if p_patch ? 'routes' then
    for v_row in select * from jsonb_array_elements(p_patch->'routes') loop
      v_rid := null;   -- cleared every turn
      if (v_row->>'route_id') is not null then
        update qvm_new_apps.pricing_route_modifiers r set
          vendor_branch_id = case when r.is_locked then r.vendor_branch_id
                                  else nullif(v_row->>'vendor_branch_id', '')::bigint end,
          to_region_id     = case when r.is_locked then r.to_region_id
                                  else nullif(v_row->>'to_region_id', '')::integer end,
          percent          = coalesce((v_row->>'percent')::numeric, r.percent),
          is_enabled       = case when r.is_locked then true
                                  else coalesce((v_row->>'is_enabled')::boolean, r.is_enabled) end,
          updated_at       = now()
        where r.route_id = (v_row->>'route_id')::bigint
        returning r.route_id into v_rid;
      end if;

      if v_rid is null then
        insert into qvm_new_apps.pricing_route_modifiers
          (vendor_branch_id, to_region_id, percent, is_enabled)
        values (nullif(v_row->>'vendor_branch_id', '')::bigint,
                nullif(v_row->>'to_region_id', '')::integer,
                coalesce((v_row->>'percent')::numeric, 0),
                coalesce((v_row->>'is_enabled')::boolean, true))
        -- The same source-and-destination pair twice is one rule, not two.
        on conflict do nothing
        returning route_id into v_rid;
      end if;

      if v_rid is not null then v_kept := v_kept || v_rid; end if;
    end loop;

    delete from qvm_new_apps.pricing_route_modifiers
     where not is_locked and not (route_id = any(v_kept));
  end if;

  if p_patch ? 'settings' then
    update qvm_new_apps.pricing_settings s set
      broker_mode          = coalesce((p_patch->'settings'->>'broker_mode')::boolean, s.broker_mode),
      modifier_cap_percent = coalesce((p_patch->'settings'->>'modifier_cap_percent')::numeric, s.modifier_cap_percent),
      source_validity_days = coalesce((p_patch->'settings'->>'source_validity_days')::integer, s.source_validity_days),
      floor_on_wholesale   = coalesce((p_patch->'settings'->>'floor_on_wholesale')::boolean, s.floor_on_wholesale),
      updated_by = auth.uid(), updated_at = now()
    where s.id = 1;
  end if;

  if p_patch ? 'sources' then
    for v_row in select * from jsonb_array_elements(p_patch->'sources') loop
      update qvm_new_apps.pricing_price_sources s set
        validity_days       = coalesce((v_row->>'validity_days')::integer, s.validity_days),
        is_active           = coalesce((v_row->>'is_active')::boolean, s.is_active),
        approved_for_policy = coalesce((v_row->>'approved_for_policy')::boolean, s.approved_for_policy),
        updated_by = auth.uid(), updated_at = now()
      where s.source_key = v_row->>'source_key';
    end loop;
  end if;

  insert into qvm_new_apps.pricing_policy_log (entity, action, before, after, changed_by)
  values ('layer2', 'update', v_before,
          jsonb_build_object(
            'settings',  (select to_jsonb(s) from qvm_new_apps.pricing_settings s where s.id = 1),
            'modifiers', (select jsonb_agg(to_jsonb(m)) from qvm_new_apps.pricing_modifiers m),
            'routes',    (select jsonb_agg(to_jsonb(r)) from qvm_new_apps.pricing_route_modifiers r)),
          auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;
-- qvm_new_apps.pricing_policies_get()
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_policies_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(

    'policies', coalesce((
      select jsonb_agg(p order by p.sort_order, p.policy_id) from (
        select pol.policy_id, pol.name, pol.audience, pol.used_for, pol.is_contractual,
               pol.is_active, pol.sort_order,
               coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'customer_id', c.customer_id,
                          'name', coalesce(c.name_ar, c.name_en, ld.list_data))
                        order by c.customer_id)
                   from qvm_new_apps.pricing_policy_customers pc
                   join qvm_new_apps.customers c on c.customer_id = pc.customer_id
                   join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
                  where pc.policy_id = pol.policy_id), '[]'::jsonb) as customers,
               coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'rule_id', r.rule_id, 'position', r.position, 'is_general', r.is_general,
                          'brand_class', r.brand_class, 'part_category', r.part_category,
                          'cost_range_id', r.cost_range_id, 'branch_id', r.branch_id,
                          'source_key', r.source_key, 'adjust_value', r.adjust_value,
                          'adjust_unit', r.adjust_unit, 'auto_fetch', r.auto_fetch,
                          'auto_send', r.auto_send)
                        -- The general rule is pinned last whatever its position.
                        order by r.is_general, r.position, r.rule_id)
                   from qvm_new_apps.pricing_policy_rules r
                  where r.policy_id = pol.policy_id), '[]'::jsonb) as rules
          from qvm_new_apps.pricing_policies pol
      ) p), '[]'::jsonb),

    -- Age is measured, never assumed. Two of these four have a real feed in
    -- the live system; the other two are named on the screen with no number
    -- rather than a plausible one, because nothing writes them yet.
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
               'source_key', s.source_key, 'label_en', s.label_en, 'label_ar', s.label_ar,
               'origin', s.origin, 'validity_days', s.validity_days, 'is_active', s.is_active,
               'approved_for_policy', s.approved_for_policy,
               'data_age_days', case s.source_key
                 when 'agency_price' then (
                   select (current_date - max(qi.updated_at)::date)
                     from qvm_new_apps.quotation_items qi
                    where qi.agency_price is not null and qi.agency_price > 0)
                 when 'last_sold_to_customer' then (
                   select (current_date - max(qi.updated_at)::date)
                     from qvm_new_apps.quotation_items qi
                    where qi.price_before_vat is not null and qi.price_before_vat > 0)
                 else null end,
               'has_feed', s.source_key in ('agency_price','last_sold_to_customer'))
             order by s.sort_order)
        from qvm_new_apps.pricing_price_sources s), '[]'::jsonb),

    'modifiers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'modifier_key', m.modifier_key, 'label_en', m.label_en, 'label_ar', m.label_ar,
               'percent', m.percent, 'is_enabled', m.is_enabled) order by m.sort_order)
        from qvm_new_apps.pricing_modifiers m), '[]'::jsonb),

    'routes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'route_id', rm.route_id, 'vendor_branch_id', rm.vendor_branch_id,
               'vendor_branch_name', case when rm.vendor_branch_id is null then null
                                          else coalesce(v.vendor_name, '') || ' — ' || coalesce(vb.branch_name, '') end,
               'to_region_id', rm.to_region_id, 'to_region_name', rg.list_data,
               'percent', rm.percent, 'is_enabled', rm.is_enabled, 'is_locked', rm.is_locked,
               -- «آخر تكلفة» on that route, so a percentage is not set blind.
               'last_cost', (
                 select round(avg(qvi.cost), 2)
                   from qvm_new_apps.quotation_vendor_items qvi
                  where rm.vendor_branch_id is not null
                    and qvi.vendor_id = vb.vendor_id
                    and qvi.cost is not null and qvi.cost > 0
                    and qvi.created_at > now() - interval '90 days'))
             -- Most specific first, baseline last: that is the order it is read in.
             order by rm.is_locked,
                      (rm.vendor_branch_id is null), (rm.to_region_id is null), rm.route_id)
        from qvm_new_apps.pricing_route_modifiers rm
        left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = rm.vendor_branch_id
        left join qvm_new_apps.vendors v on v.vendor_id = vb.vendor_id
        left join qvm_new_apps.list_data rg on rg.list_data_id = rm.to_region_id), '[]'::jsonb),

    'settings', (select to_jsonb(s) from qvm_new_apps.pricing_settings s where s.id = 1),

    'options', jsonb_build_object(
      'brand_classes', coalesce((select jsonb_agg(jsonb_build_object('id', list_data_id, 'name', list_data) order by list_data_id)
                                   from qvm_new_apps.list_data where list_id = 5), '[]'::jsonb),
      'part_categories', coalesce((select jsonb_agg(jsonb_build_object('id', list_data_id, 'name', list_data) order by list_data_id)
                                     from qvm_new_apps.list_data where list_id = 6), '[]'::jsonb),
      'regions', coalesce((select jsonb_agg(jsonb_build_object('id', list_data_id, 'name', list_data) order by list_data_id)
                             from qvm_new_apps.list_data where list_id = 2), '[]'::jsonb),
      'cost_ranges', coalesce((select jsonb_agg(jsonb_build_object(
                                 'id', cost_range_id,
                                 'from', (cost_range->>0)::numeric, 'to', (cost_range->>1)::numeric)
                               order by cost_range_id)
                                 from qvm_new_apps.cost_categories), '[]'::jsonb),
      'branches', coalesce((select jsonb_agg(jsonb_build_object(
                              'id', b.customer_id, 'name', b.branch_name, 'company', ld.list_data)
                            order by ld.list_data, b.branch_name)
                              from qvm_new_apps.client_branches b
                              join qvm_new_apps.list_data ld on ld.list_data_id = b.list_data_id), '[]'::jsonb),
      'vendor_branches', coalesce((select jsonb_agg(jsonb_build_object(
                              'id', vb.vendor_branch_id,
                              'name', coalesce(v.vendor_name,'') || ' — ' || coalesce(vb.branch_name,''))
                            order by v.vendor_name, vb.branch_name)
                              from qvm_new_apps.vendor_branches vb
                              join qvm_new_apps.vendors v on v.vendor_id = vb.vendor_id
                             where coalesce(vb.is_active, true)), '[]'::jsonb),
      'customers', coalesce((select jsonb_agg(jsonb_build_object(
                              'id', c.customer_id,
                              'name', coalesce(c.name_ar, c.name_en, ld.list_data),
                              'customer_type', c.customer_type,
                              -- Already spoken for by another policy of the same purpose.
                              'taken_for', (select jsonb_agg(distinct pc.used_for)
                                              from qvm_new_apps.pricing_policy_customers pc
                                             where pc.customer_id = c.customer_id))
                            order by coalesce(c.name_ar, c.name_en, ld.list_data))
                              from qvm_new_apps.customers c
                              join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
                             where c.is_active and c.merged_into is null), '[]'::jsonb)
    )
  ));
end
$function$;
-- qvm_new_apps.pricing_policy_delete(p_policy_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_policy_delete(p_policy_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_before jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select to_jsonb(p) into v_before from qvm_new_apps.pricing_policies p where p.policy_id = p_policy_id;
  if v_before is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  -- Rules and links go with it; the log entry is what survives.
  delete from qvm_new_apps.pricing_policies where policy_id = p_policy_id;

  insert into qvm_new_apps.pricing_policy_log
    (policy_id, entity, entity_id, action, before, changed_by)
  values (p_policy_id, 'policy', p_policy_id::text, 'delete', v_before, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;
-- qvm_new_apps.pricing_policy_save(p_policy_id bigint, p_patch jsonb)
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_policy_save(p_policy_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_id bigint := p_policy_id; v_before jsonb; v_after jsonb; v_used text;
  v_rule jsonb; v_pos integer := 0; v_kept bigint[] := '{}'; v_rid bigint; v_clash text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_patch->>'name', '')), '') is null then
    return jsonb_build_object('status', false, 'message', 'اسم السياسة مطلوب', 'data', null);
  end if;

  if v_id is null then
    insert into qvm_new_apps.pricing_policies
      (name, audience, used_for, is_contractual, is_active, sort_order, created_by)
    values (btrim(p_patch->>'name'),
            coalesce(p_patch->>'audience', 'companies'),
            coalesce(p_patch->>'used_for', 'quoted'),
            coalesce((p_patch->>'is_contractual')::boolean, false),
            coalesce((p_patch->>'is_active')::boolean, true),
            coalesce((p_patch->>'sort_order')::integer,
                     (select coalesce(max(sort_order), 0) + 1 from qvm_new_apps.pricing_policies)),
            auth.uid())
    returning policy_id into v_id;
  else
    select to_jsonb(p) into v_before from qvm_new_apps.pricing_policies p where p.policy_id = v_id;
    if v_before is null then
      return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
    end if;
    update qvm_new_apps.pricing_policies p set
      name           = coalesce(nullif(btrim(p_patch->>'name'), ''), p.name),
      audience       = coalesce(p_patch->>'audience', p.audience),
      used_for       = coalesce(p_patch->>'used_for', p.used_for),
      is_contractual = coalesce((p_patch->>'is_contractual')::boolean, p.is_contractual),
      is_active      = coalesce((p_patch->>'is_active')::boolean, p.is_active),
      sort_order     = coalesce((p_patch->>'sort_order')::integer, p.sort_order),
      updated_at     = now()
    where p.policy_id = v_id;
  end if;

  select used_for into v_used from qvm_new_apps.pricing_policies where policy_id = v_id;

  if p_patch ? 'customer_ids' then
    select coalesce(c.name_ar, c.name_en, ld.list_data) || ' — ' || pol.name into v_clash
      from jsonb_array_elements_text(p_patch->'customer_ids') x(cid)
      join qvm_new_apps.pricing_policy_customers pc
        on pc.customer_id = x.cid::bigint and pc.used_for = v_used and pc.policy_id <> v_id
      join qvm_new_apps.pricing_policies pol on pol.policy_id = pc.policy_id
      join qvm_new_apps.customers c on c.customer_id = pc.customer_id
      join qvm_new_apps.list_data ld on ld.list_data_id = c.list_data_id
     limit 1;
    if v_clash is not null then
      return jsonb_build_object('status', false,
        'message', 'هذا العميل مرتبط بسياسة أخرى لنفس الغرض: ' || v_clash, 'data', null);
    end if;
    delete from qvm_new_apps.pricing_policy_customers where policy_id = v_id;
    insert into qvm_new_apps.pricing_policy_customers (policy_id, customer_id, used_for)
    select v_id, x.cid::bigint, v_used
      from jsonb_array_elements_text(coalesce(p_patch->'customer_ids', '[]'::jsonb)) x(cid);
  end if;

  if p_patch ? 'rules' then
    for v_rule in select * from jsonb_array_elements(p_patch->'rules') loop
      v_pos := v_pos + 1;
      v_rid := null;   -- cleared every turn, so a miss cannot inherit the last id
      if (v_rule->>'rule_id') is not null then
        update qvm_new_apps.pricing_policy_rules r set
          position      = v_pos,
          brand_class   = nullif(v_rule->>'brand_class', '')::integer,
          part_category = nullif(v_rule->>'part_category', '')::integer,
          cost_range_id = nullif(v_rule->>'cost_range_id', '')::integer,
          branch_id     = nullif(v_rule->>'branch_id', '')::integer,
          source_key    = nullif(v_rule->>'source_key', ''),
          adjust_value  = coalesce((v_rule->>'adjust_value')::numeric, 0),
          adjust_unit   = coalesce(v_rule->>'adjust_unit', 'percent'),
          auto_fetch    = coalesce((v_rule->>'auto_fetch')::boolean, true),
          auto_send     = coalesce((v_rule->>'auto_send')::boolean, false),
          updated_at    = now()
        where r.rule_id = (v_rule->>'rule_id')::bigint and r.policy_id = v_id
        returning r.rule_id into v_rid;
      end if;

      if v_rid is null then
        insert into qvm_new_apps.pricing_policy_rules
          (policy_id, position, is_general, brand_class, part_category, cost_range_id,
           branch_id, source_key, adjust_value, adjust_unit, auto_fetch, auto_send)
        values (v_id, v_pos, coalesce((v_rule->>'is_general')::boolean, false),
                nullif(v_rule->>'brand_class', '')::integer,
                nullif(v_rule->>'part_category', '')::integer,
                nullif(v_rule->>'cost_range_id', '')::integer,
                nullif(v_rule->>'branch_id', '')::integer,
                nullif(v_rule->>'source_key', ''),
                coalesce((v_rule->>'adjust_value')::numeric, 0),
                coalesce(v_rule->>'adjust_unit', 'percent'),
                coalesce((v_rule->>'auto_fetch')::boolean, true),
                coalesce((v_rule->>'auto_send')::boolean, false))
        -- Two general rules cannot exist; if one is already there, keep it.
        on conflict do nothing
        returning rule_id into v_rid;
      end if;

      if v_rid is not null then v_kept := v_kept || v_rid; end if;
    end loop;

    delete from qvm_new_apps.pricing_policy_rules
     where policy_id = v_id and not (rule_id = any(v_kept));
  end if;

  if not exists (select 1 from qvm_new_apps.pricing_policy_rules where policy_id = v_id and is_general) then
    insert into qvm_new_apps.pricing_policy_rules (policy_id, position, is_general, source_key)
    values (v_id, 999, true, null);
  end if;

  select to_jsonb(p) into v_after from qvm_new_apps.pricing_policies p where p.policy_id = v_id;
  insert into qvm_new_apps.pricing_policy_log
    (policy_id, entity, entity_id, action, before, after, changed_by)
  values (v_id, 'policy', v_id::text,
          case when p_policy_id is null then 'create' else 'update' end,
          v_before, v_after, auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('policy_id', v_id));
end
$function$;
-- qvm_new_apps.pricing_simulate(p_input jsonb)
CREATE OR REPLACE FUNCTION qvm_new_apps.pricing_simulate(p_input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_wholesale   numeric := coalesce((p_input->>'wholesale_price')::numeric, 0);
  v_brand       integer := nullif(p_input->>'brand_class', '')::integer;
  v_part        integer := nullif(p_input->>'part_category', '')::integer;
  v_branch      integer := nullif(p_input->>'branch_id', '')::integer;
  v_customer    bigint  := nullif(p_input->>'customer_id', '')::bigint;
  v_vbranch     bigint  := nullif(p_input->>'vendor_branch_id', '')::bigint;
  v_region      integer := nullif(p_input->>'to_region_id', '')::integer;
  v_used_for    text    := coalesce(p_input->>'used_for', 'quoted');
  v_conditions  text[]  := coalesce(array(select jsonb_array_elements_text(p_input->'conditions')), '{}');
  v_target      numeric := nullif(p_input->>'target_price', '')::numeric;
  v_agency      numeric := nullif(p_input->>'agency_price', '')::numeric;
  v_prices      jsonb   := coalesce(p_input->'source_prices', '{}'::jsonb);

  v_settings    record;
  v_cost_range  integer;
  v_cat         integer;
  v_margin      numeric;
  v_layer0      numeric;
  v_layer1      numeric;
  v_layer2      numeric;
  v_final       numeric;
  v_policy      record;
  v_rule        record;
  v_picked      record;
  v_start       numeric;
  v_cond_total  numeric := 0;
  v_route       record;
  v_route_pct   numeric := 0;
  v_l2_total    numeric := 0;
  v_capped      boolean := false;
  v_notes       jsonb := '[]'::jsonb;
  v_manual      text := null;
  v_l0_note     text;
  v_l1_note     text;
  v_l2_note     text;
  v_l3_note     text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_wholesale <= 0 then
    return jsonb_build_object('status', false, 'message', 'سعر الجملة مطلوب', 'data', null);
  end if;

  select * into v_settings from qvm_new_apps.pricing_settings where id = 1;

  -- Which policy prices this customer, for this purpose.
  select pol.* into v_policy
    from qvm_new_apps.pricing_policy_customers pc
    join qvm_new_apps.pricing_policies pol on pol.policy_id = pc.policy_id
   where pc.customer_id = v_customer and pc.used_for = v_used_for and pol.is_active
   limit 1;

  -- ── the contractual short circuit ─────────────────────────────────────────
  -- A signed contract is a closed path: agency price, fixed, layers 0, 2 and 3
  -- never run. Without an agency price there is nothing to price from at all.
  if v_policy.policy_id is not null and v_policy.is_contractual then
    select r.* into v_rule from qvm_new_apps.pricing_policy_rules r
     where r.policy_id = v_policy.policy_id order by r.is_general, r.position limit 1;

    if v_agency is null then
      return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
        'contractual', true, 'manual_reason', 'no_agency_price',
        'layers', jsonb_build_array(
          jsonb_build_object('layer', 1, 'title', v_policy.name,
                             'note', 'عقد موقّع — لا يوجد سعر وكالة لهذه القطعة', 'value', null)),
        'final_price', null, 'guard', jsonb_build_object('ok', false, 'floor', v_wholesale)));
    end if;

    v_final := case when coalesce(v_rule.adjust_unit, 'percent') = 'sar'
                    then v_agency + coalesce(v_rule.adjust_value, 0)
                    else v_agency * (1 + coalesce(v_rule.adjust_value, 0) / 100) end;

    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'contractual', true,
      'policy', jsonb_build_object('policy_id', v_policy.policy_id, 'name', v_policy.name),
      'layers', jsonb_build_array(
        jsonb_build_object('layer', 0, 'title', 'قواعد الهامش', 'note', 'يتخطاها العقد الموقّع', 'value', null),
        jsonb_build_object('layer', 1, 'title', v_policy.name,
          'note', 'سعر الوكالة ' || round(v_agency, 2) || ' · ' ||
                  coalesce(v_rule.adjust_value, 0) ||
                  case when coalesce(v_rule.adjust_unit,'percent') = 'sar' then ' ريال' else '%' end,
          'value', round(v_final, 2)),
        jsonb_build_object('layer', 2, 'title', 'الطبقة الإضافية', 'note', 'لا تُطبَّق على عقد موقّع', 'value', round(v_final, 2)),
        jsonb_build_object('layer', 3, 'title', 'السعر المستهدف', 'note', 'لا تفاوض فوق عقد موقّع', 'value', null)),
      'final_price', round(v_final, 2),
      'guard', jsonb_build_object('ok', v_final > v_wholesale, 'floor', v_wholesale)));
  end if;

  -- ── layer 0: the margin rules ─────────────────────────────────────────────
  select cost_range_id into v_cost_range from qvm_new_apps.cost_categories
   where v_wholesale >= (cost_range->>0)::numeric and v_wholesale < (cost_range->>1)::numeric
   order by cost_range_id limit 1;

  select category_id into v_cat from qvm_new_apps.profit_categories
   where brand_class is not distinct from v_brand and part_category is not distinct from v_part;

  if v_cat is not null and v_cost_range is not null then
    -- The branch override wins over the global percentage — the same
    -- COALESCE the profit-percentages screen has always used.
    select coalesce(
      (select b.percentage from qvm_new_apps.profit_margins_branch b
        where b.branch_id = v_branch and b.profit_categories_id = v_cat and b.cost_range_id = v_cost_range),
      (select m.percentage from qvm_new_apps.profit_margins m
        where m.profit_categories_id = v_cat and m.cost_range_id = v_cost_range))
      into v_margin;
  end if;

  if v_margin is null then
    v_margin := 0;
    v_l0_note := 'لا توجد نسبة ربح مطابقة — استُخدم صفر';
    v_notes := v_notes || to_jsonb('no_margin_match'::text);
  else
    v_l0_note := coalesce((select list_data from qvm_new_apps.list_data where list_data_id = v_part), 'كل الفئات')
              || ' × ' || coalesce((select list_data from qvm_new_apps.list_data where list_data_id = v_brand), 'كل الأصناف')
              || ' × ' || coalesce((select (cost_range->>0) || '–' || (cost_range->>1)
                                      from qvm_new_apps.cost_categories where cost_range_id = v_cost_range), '—')
              || coalesce(' × ' || (select branch_name from qvm_new_apps.client_branches where customer_id = v_branch), '')
              || ' = ' || v_margin || '% على ' || round(v_wholesale, 2);
  end if;
  v_layer0 := v_wholesale * (1 + v_margin / 100);

  -- ── layer 1: the customer's policy ────────────────────────────────────────
  v_layer1 := v_layer0;
  if v_policy.policy_id is null then
    v_l1_note := 'لا توجد سياسة مرتبطة بهذا العميل — يبقى السعر الافتراضي';
  else
    -- Rules are tried in order. A rule whose starting price is not available
    -- is skipped rather than failing the whole policy.
    for v_rule in
      select r.* from qvm_new_apps.pricing_policy_rules r
       where r.policy_id = v_policy.policy_id
       order by r.is_general, r.position, r.rule_id
    loop
      -- Null on a dimension means «all», so it matches anything.
      if (v_rule.brand_class   is null or v_rule.brand_class   = v_brand)
         and (v_rule.part_category is null or v_rule.part_category = v_part)
         and (v_rule.cost_range_id is null or v_rule.cost_range_id = v_cost_range)
         and (v_rule.branch_id     is null or v_rule.branch_id     = v_branch)
      then
        if v_rule.source_key is null then
          v_start := v_layer0;                       -- «ابدأ من سعري الافتراضي»
        elsif v_prices ? v_rule.source_key then
          v_start := (v_prices->>v_rule.source_key)::numeric;
        elsif v_rule.source_key = 'agency_price' and v_agency is not null then
          v_start := v_agency;
        else
          v_start := null;                            -- unavailable → next rule
        end if;

        if v_start is not null then
          -- A source the admin has not approved may not price anything.
          if v_rule.source_key is not null and not exists (
               select 1 from qvm_new_apps.pricing_price_sources s
                where s.source_key = v_rule.source_key and s.is_active and s.approved_for_policy) then
            v_notes := v_notes || to_jsonb(('source_not_approved:' || v_rule.source_key)::text);
          else
            v_picked := v_rule;
            v_layer1 := case when v_rule.adjust_unit = 'sar'
                             then v_start + v_rule.adjust_value
                             else v_start * (1 + v_rule.adjust_value / 100) end;
            exit;
          end if;
        end if;
      end if;
    end loop;

    if v_picked.rule_id is null then
      v_l1_note := 'سياسة «' || v_policy.name || '» — لا قاعدة صالحة، التسعير يدوي';
      v_manual := 'no_rule_matched';
    else
      v_l1_note := 'سياسة «' || v_policy.name || '» — يبدأ من '
                || coalesce((select label_ar from qvm_new_apps.pricing_price_sources
                              where source_key = v_picked.source_key), 'سعري الافتراضي')
                || ' · ' || v_picked.adjust_value
                || case when v_picked.adjust_unit = 'sar' then ' ريال' else '%' end;
    end if;
  end if;

  -- ── layer 2: the extra layer ──────────────────────────────────────────────
  -- Part conditions stack; a part can be slow-moving and missing at once.
  select coalesce(sum(m.percent), 0) into v_cond_total
    from qvm_new_apps.pricing_modifiers m
   where m.is_enabled and m.modifier_key = any(v_conditions);

  -- Routes do not: an order has one source and one destination, so the most
  -- specific matching row wins and the rest are ignored.
  select rm.* into v_route
    from qvm_new_apps.pricing_route_modifiers rm
   where rm.is_enabled
     and (rm.vendor_branch_id is null or rm.vendor_branch_id = v_vbranch)
     and (rm.to_region_id     is null or rm.to_region_id     = v_region)
   order by (rm.vendor_branch_id is null), (rm.to_region_id is null), rm.route_id
   limit 1;
  v_route_pct := coalesce(v_route.percent, 0);

  v_l2_total := v_cond_total + v_route_pct;
  if abs(v_l2_total) > v_settings.modifier_cap_percent then
    v_l2_total := sign(v_l2_total) * v_settings.modifier_cap_percent;
    v_capped := true;
  end if;
  v_layer2 := v_layer1 * (1 + v_l2_total / 100);

  v_l2_note := 'الحالة ' || v_cond_total || '% + المسار ' || v_route_pct || '% = ' || v_l2_total || '%'
            || case when v_capped then ' (بلغ الحد ±' || v_settings.modifier_cap_percent || '%)' else '' end;

  -- ── layer 3: the customer's target price ──────────────────────────────────
  if v_target is null then
    v_final := v_layer2;
    v_l3_note := 'لا يوجد سعر مستهدف من العميل';
  else
    v_final := v_target;
    v_l3_note := 'سعر مستهدف من العميل: ' || round(v_target, 2);
  end if;

  -- ── the guard ─────────────────────────────────────────────────────────────
  -- Measured on the final number after every layer, not on any one of them.
  if v_settings.floor_on_wholesale and v_final <= v_wholesale then
    v_manual := coalesce(v_manual, 'below_floor');
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'contractual', false,
    'policy', case when v_policy.policy_id is null then null
                   else jsonb_build_object('policy_id', v_policy.policy_id, 'name', v_policy.name) end,
    'layers', jsonb_build_array(
      jsonb_build_object('layer', 0, 'title', 'قواعد الهامش — سعري الافتراضي', 'note', v_l0_note, 'value', round(v_layer0, 2)),
      jsonb_build_object('layer', 1, 'title', 'سياسة العميل', 'note', v_l1_note, 'value', round(v_layer1, 2)),
      jsonb_build_object('layer', 2, 'title', 'الطبقة الإضافية', 'note', v_l2_note, 'value', round(v_layer2, 2)),
      jsonb_build_object('layer', 3, 'title', 'السعر المستهدف', 'note', v_l3_note,
                         'value', case when v_target is null then null else round(v_target, 2) end)),
    'final_price', round(v_final, 2),
    'manual_reason', v_manual,
    'notes', v_notes,
    'guard', jsonb_build_object(
      'ok', v_final > v_wholesale, 'floor', round(v_wholesale, 2), 'final', round(v_final, 2))));
end
$function$;
-- qvm_new_apps.quick_send_item_to_vendors(p_quotation_item_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.quick_send_item_to_vendors(p_quotation_item_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_quotation_id integer;
  v_order_number text; v_plate text; v_date date;
  v_vin text; v_brand text; v_model text; v_year text; v_class text;
  v_part_number text; v_part_desc text; v_qty integer;
  v_created jsonb := '[]'::jsonb;
  v_count int := 0;
  r record;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated');
  end if;

  select qi.quotation_id, qi.vin, qi.model, bmain.list_data, bcls.list_data,
         qi.part_number, qi.part_description, qi.quantity, qi.year::text
    into v_quotation_id, v_vin, v_model, v_brand, v_class,
         v_part_number, v_part_desc, v_qty, v_year
  from qvm_new_apps.quotation_items qi
  left join qvm_new_apps.list_data bmain on bmain.list_data_id = qi.main_brand
  left join qvm_new_apps.list_data bcls on bcls.list_data_id = qi.brand_class
  where qi.quotation_item_id = p_quotation_item_id;

  if v_quotation_id is null then
    return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id');
  end if;

  select q.order_number, q.plate_number, q.created_at::date
    into v_order_number, v_plate, v_date
  from qvm_new_apps.quotations q where q.quotation_id = v_quotation_id;

  for r in
    select qv.quotation_vendor_id, qv.vendor_id, qv.vendor_branch_id, qv.access_token
    from qvm_new_apps.quotation_vendors qv
    where qv.quotation_id = v_quotation_id
  loop
    insert into qvm_new_apps.quotation_vendor_items (
      quotation_item_id, vendor_id, quotation_vendor_id,
      best_cost, from_database, vendor_item_status, created_by, created_at, updated_at
    ) values (
      p_quotation_item_id, r.vendor_id, r.quotation_vendor_id,
      false, false, 157, v_uid, now(), now()
    )
    on conflict on constraint quotation_vendor_items_quotation_item_qv_unique do nothing;

    -- keep each vendor's magic link alive (same 7-day window as a resend)
    update qvm_new_apps.quotation_vendors
      set token_expires_at = now() + interval '7 days'
      where quotation_vendor_id = r.quotation_vendor_id;

    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'vendor_id', r.vendor_id,
      'vendor_branch_id', r.vendor_branch_id,
      'quotation_vendor_id', r.quotation_vendor_id,
      'access_token', r.access_token
    ));
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    return jsonb_build_object('status', false, 'message', 'No vendors are attached to this quotation yet');
  end if;

  update qvm_new_apps.quotation_items
    set item_status = 237, updated_at = now()
    where quotation_item_id = p_quotation_item_id;

  insert into qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  values (p_quotation_item_id, 237, v_uid, now())
  on conflict do nothing;

  return jsonb_build_object(
    'status', true,
    'quotation_id', v_quotation_id,
    'order_number', coalesce(v_order_number, ''),
    'date', coalesce(v_date::text, now()::date::text),
    'car_data', jsonb_build_object(
      'vin', coalesce(v_vin, ''), 'make', coalesce(v_brand, ''), 'model', coalesce(v_model, ''),
      'year', coalesce(nullif(v_year, '')::int, 0), 'plate_number', coalesce(v_plate, '')
    ),
    'item_list', jsonb_build_array(jsonb_build_object(
      'part_number', coalesce(v_part_number, ''), 'part_description', coalesce(v_part_desc, ''),
      'class', coalesce(v_class, ''), 'qty', coalesce(v_qty, 1)
    )),
    'created', v_created,
    'created_count', v_count
  );
end $function$;
-- qvm_new_apps.release_all_extract_locks()
CREATE OR REPLACE FUNCTION qvm_new_apps.release_all_extract_locks()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then return jsonb_build_object('status', true, 'message', 'No session', 'released', 0); end if;
  with upd as (
    update qvm_new_apps.quotations
      set extract_locked_by = null, extract_locked_at = null, extract_lock_touched_at = null
    where extract_locked_by = v_uid
    returning 1
  ) select count(*) into v_n from upd;
  return jsonb_build_object('status', true, 'message', 'OK', 'released', v_n);
end $function$;
-- qvm_new_apps.remove_extract_alt_pn(p_quotation_item_id integer, p_alt text)
CREATE OR REPLACE FUNCTION qvm_new_apps.remove_extract_alt_pn(p_quotation_item_id integer, p_alt text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_qid integer; v_alt text := upper(btrim(coalesce(p_alt,'')));
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  select quotation_id into v_qid from qvm_new_apps.quotation_items where quotation_item_id = p_quotation_item_id;
  delete from qvm_new_apps.quotation_item_alt_pns
   where quotation_item_id = p_quotation_item_id and alt_part_number = v_alt;
  perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'alt_removed', v_alt, null);
  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'OK');
end $function$;
-- qvm_new_apps.remove_extract_item(p_quotation_item_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.remove_extract_item(p_quotation_item_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_qid integer; v_added boolean; v_creator uuid; v_status integer; v_desc text;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;

  select quotation_id, coalesce(added_at_extraction, false), created_by, item_status, coalesce(part_description,'')
    into v_qid, v_added, v_creator, v_status, v_desc
  from qvm_new_apps.quotation_items where quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;

  if not v_added then
    return jsonb_build_object('status', false, 'message', 'Only items added during extraction can be removed');
  end if;
  if v_creator is distinct from v_uid then
    return jsonb_build_object('status', false, 'message', 'Only the extractor who added this item can remove it');
  end if;
  if v_status not in (235, 236) then
    return jsonb_build_object('status', false, 'message', 'This order has already left Extract PN');
  end if;

  perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'item_removed', v_desc, null);
  delete from qvm_new_apps.quotation_item_alt_pns where quotation_item_id = p_quotation_item_id;
  delete from qvm_new_apps.quotation_items where quotation_item_id = p_quotation_item_id;

  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'Item removed');
end $function$;
-- qvm_new_apps.save_all_extract_drafts(p_quotation_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.save_all_extract_drafts(p_quotation_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  with upd as (
    update qvm_new_apps.quotation_items
    set part_number = draft_part_number, draft_part_number = null, pn_state = 'saved',
        pn_saved_by = v_uid, pn_saved_at = now(), item_status = 235, updated_at = now()
    where quotation_id = p_quotation_id and pn_state = 'draft'
      and draft_part_number is not null and length(btrim(draft_part_number)) >= 3
    returning quotation_item_id, part_number
  ), logged as (
    insert into qvm_new_apps.quotation_item_extraction_events
      (quotation_item_id, quotation_id, event_type, new_value, actor)
    select u.quotation_item_id, p_quotation_id, 'pn_saved', u.part_number, v_uid from upd u
    returning 1
  ) select count(*) into v_n from logged;
  perform qvm_new_apps._touch_extract_lock(p_quotation_id);
  return jsonb_build_object('status', true, 'message', 'OK', 'published', v_n);
end $function$;
-- qvm_new_apps.search_vendor_users_for_rfq(p_search text)
CREATE OR REPLACE FUNCTION qvm_new_apps.search_vendor_users_for_rfq(p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_result jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = auth.uid()
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE(jsonb_agg(entry), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT entry, vendor_name, sort_name
    FROM (
      SELECT
        jsonb_build_object(
          'user_id', u.user_id,
          'user_name', u.user_name,
          'email', u.email,
          'vendor_id', u.user_vendor,
          'vendor_name', v.vendor_name,
          'user_role', ur.list_data,
          'branches', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                     'vendor_branch_id', vb.vendor_branch_id,
                     'branch_name', vb.branch_name,
                     'city', vb.city
                   ) ORDER BY vb.city, vb.branch_name)
            FROM qvm_new_apps.vendor_branch_users vbu
            JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = vbu.vendor_branch_id
            WHERE vbu.user_id = u.user_id
          ), '[]'::jsonb)
        ) AS entry,
        v.vendor_name,
        u.user_name AS sort_name
      FROM qvm_new_apps.user_data u
      JOIN qvm_new_apps.vendors v ON v.vendor_id = u.user_vendor
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_type = 205
        AND (
          p_search IS NULL OR p_search = '' OR
          u.user_name ILIKE '%'||p_search||'%' OR
          u.email ILIKE '%'||p_search||'%' OR
          v.vendor_name ILIKE '%'||p_search||'%'
        )

      UNION ALL

      SELECT
        jsonb_build_object(
          'user_id', 'company:' || v.vendor_id,
          'user_name', v.vendor_name,
          'email', v.email,
          'vendor_id', v.vendor_id,
          'vendor_name', v.vendor_name,
          'user_role', NULL,
          'branches', '[]'::jsonb
        ) AS entry,
        v.vendor_name,
        v.vendor_name AS sort_name
      FROM qvm_new_apps.vendors v
      WHERE NOT EXISTS (
        SELECT 1 FROM qvm_new_apps.user_data u2 WHERE u2.user_vendor = v.vendor_id AND u2.user_type = 205
      )
      AND (p_search IS NULL OR p_search = '' OR v.vendor_name ILIKE '%'||p_search||'%')
    ) combined
    ORDER BY vendor_name, sort_name
    LIMIT 100
  ) limited;

  RETURN v_result;
END;
$function$;
-- qvm_new_apps.set_extract_description(p_quotation_item_id integer, p_description text)
CREATE OR REPLACE FUNCTION qvm_new_apps.set_extract_description(p_quotation_item_id integer, p_description text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_qid integer;
  v_order text;
  v_old text;
  v_new text := btrim(coalesce(p_description, ''));
  v_actor text;
  v_was_unclear boolean;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  if v_new = '' then return jsonb_build_object('status', false, 'message', 'Part description is required'); end if;

  select qi.quotation_id, q.order_number, coalesce(qi.part_description, ''),
         (qi.extraction_status = 'unclear')
    into v_qid, v_order, v_old, v_was_unclear
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;

  if v_old = v_new then
    return jsonb_build_object('status', true, 'message', 'Unchanged');
  end if;

  select coalesce(user_name, 'Extraction') into v_actor from qvm_new_apps.user_data where user_id = v_uid;

  update qvm_new_apps.quotation_items
    set part_description = v_new,
        -- a clarified description resolves the Unclear flag; the row goes back to "No PN yet"
        extraction_status = case when coalesce(v_was_unclear, false) then null else extraction_status end,
        extraction_unclear_reason = case when coalesce(v_was_unclear, false) then null else extraction_unclear_reason end,
        extraction_flagged_by = case when coalesce(v_was_unclear, false) then null else extraction_flagged_by end,
        extraction_flagged_at = case when coalesce(v_was_unclear, false) then null else extraction_flagged_at end,
        updated_at = now()
    where quotation_item_id = p_quotation_item_id;

  perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'description_amended', v_old, v_new);
  if coalesce(v_was_unclear, false) then
    perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'unclear_resolved', 'description updated', null);
  end if;

  begin
    perform public.upsert_note_inline(
      p_note_type := 'quotation_items',
      p_type_id := p_quotation_item_id,
      p_note_description := format('%s — description amended during Extract PN: "%s" → "%s" by %s.',
                                   v_order, v_old, v_new, v_actor),
      p_note_id := null,
      p_is_internal := false
    );
  exception when others then null;
  end;

  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'OK',
                            'data', jsonb_build_object('unclear_resolved', coalesce(v_was_unclear, false)));
end $function$;
-- qvm_new_apps.set_extract_pn(p_quotation_item_id integer, p_part_number text, p_mode text)
CREATE OR REPLACE FUNCTION qvm_new_apps.set_extract_pn(p_quotation_item_id integer, p_part_number text, p_mode text DEFAULT 'draft'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_qid integer;
  v_pn text;
  v_old_pn text;
  v_old_state text;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  -- story 8: trimmed + upper-cased
  v_pn := upper(btrim(coalesce(p_part_number, '')));

  select quotation_id, coalesce(part_number, draft_part_number), pn_state
    into v_qid, v_old_pn, v_old_state
  from qvm_new_apps.quotation_items where quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;

  if p_mode = 'save' then
    -- row-level validation: a real PN is at least 3 characters
    if length(v_pn) < 3 then
      return jsonb_build_object('status', false, 'message', 'Part number must be at least 3 characters');
    end if;
    -- story 8: an alternate may not duplicate the primary
    if exists (select 1 from qvm_new_apps.quotation_item_alt_pns a
               where a.quotation_item_id = p_quotation_item_id and a.alt_part_number = v_pn) then
      return jsonb_build_object('status', false, 'message', 'This part number is already listed as an alternate');
    end if;
    update qvm_new_apps.quotation_items
      set part_number = v_pn, draft_part_number = null, pn_state = 'saved',
          pn_saved_by = v_uid, pn_saved_at = now(), item_status = 235,
          extraction_status = null, extraction_unclear_reason = null, updated_at = now()
      where quotation_item_id = p_quotation_item_id;
    perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'pn_saved', v_old_pn, v_pn);

  elsif p_mode = 'clear' then
    update qvm_new_apps.quotation_items
      set draft_part_number = null, part_number = null, pn_state = 'none',
          item_status = 236, updated_at = now()
      where quotation_item_id = p_quotation_item_id;
    perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'pn_cleared', v_old_pn, null);

  else -- draft: persisted server-side but NOT exposed to purchasing
    update qvm_new_apps.quotation_items
      set draft_part_number = nullif(v_pn, ''), part_number = null,
          pn_state = case when v_pn = '' then 'none' else 'draft' end,
          item_status = 236,
          extraction_status = null, extraction_unclear_reason = null, updated_at = now()
      where quotation_item_id = p_quotation_item_id;
    -- reopening an already-published PN is a different event from a first draft
    perform qvm_new_apps._log_extract_event(
      p_quotation_item_id,
      case when v_old_state = 'saved' then 'pn_reopened' else 'pn_draft' end,
      v_old_pn, nullif(v_pn, ''));
  end if;

  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'OK');
end $function$;
-- qvm_new_apps.set_extract_unclear(p_quotation_item_id integer, p_reason text, p_clear boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.set_extract_unclear(p_quotation_item_id integer, p_reason text, p_clear boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_qid integer;
  v_order text;
  v_desc text;
  v_old_reason text;
  v_actor text;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;

  select qi.quotation_id, q.order_number, coalesce(qi.part_description, ''), qi.extraction_unclear_reason
    into v_qid, v_order, v_desc, v_old_reason
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;

  select coalesce(user_name, 'Extraction') into v_actor from qvm_new_apps.user_data where user_id = v_uid;

  if p_clear then
    update qvm_new_apps.quotation_items
      set extraction_status = null, extraction_unclear_reason = null,
          extraction_flagged_by = null, extraction_flagged_at = null, updated_at = now()
      where quotation_item_id = p_quotation_item_id;
    perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'unclear_resolved', v_old_reason, null);
  else
    if coalesce(btrim(p_reason), '') = '' then
      return jsonb_build_object('status', false, 'message', 'A reason is required');
    end if;
    update qvm_new_apps.quotation_items
      set extraction_status = 'unclear', extraction_unclear_reason = btrim(p_reason),
          extraction_flagged_by = v_uid, extraction_flagged_at = now(),
          draft_part_number = null, pn_state = 'none', updated_at = now()
      where quotation_item_id = p_quotation_item_id;
    perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'unclear_raised', v_old_reason, btrim(p_reason));

    -- Notify the branch / account manager on the item itself. Best-effort: a failed note must not
    -- roll back the flag.
    begin
      perform public.upsert_note_inline(
        p_note_type := 'quotation_items',
        p_type_id := p_quotation_item_id,
        p_note_description := format('%s — %s: "%s" needs clarification (%s). Raised by %s.',
                                     v_order, 'Extract PN', v_desc, btrim(p_reason), v_actor),
        p_note_id := null,
        p_is_internal := false
      );
    exception when others then null;
    end;
  end if;

  perform qvm_new_apps._touch_extract_lock(v_qid);
  return jsonb_build_object('status', true, 'message', 'OK');
end $function$;
-- qvm_new_apps.upload_batch_clear_rows(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_clear_rows(p_batch_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_removed integer := 0;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then return 0; end if;

  case v_b.template_key
    when 'agency_price_list' then delete from qvm_new_apps.agency_price_reference where batch_id = p_batch_id;
    when 'stock_on_hand'     then delete from qvm_new_apps.inventory_stock where batch_id = p_batch_id;
    when 'past_purchases'    then delete from qvm_new_apps.part_purchase_history where batch_id = p_batch_id;
    when 'aliases'           then delete from qvm_new_apps.part_aliases where batch_id = p_batch_id;
    when 'offers'            then delete from qvm_new_apps.part_offers where batch_id = p_batch_id;
    when 'group_import_request' then delete from qvm_new_apps.group_import_requests where batch_id = p_batch_id;
    when 'stock_auction'     then delete from qvm_new_apps.stock_auction_items where batch_id = p_batch_id;
    else raise exception 'نوع ملف غير معروف: %', v_b.template_key;
  end case;
  get diagnostics v_removed = row_count;
  return v_removed;
end
$function$;
-- qvm_new_apps.upload_batch_delete_data(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_delete_data(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false,
      'message', 'حذف البيانات المنشورة يحتاج موافقة فريق بترومين — أرسل طلب حذف', 'data', null);
  end if;
  return qvm_new_apps.upload_batch_delete_data_run(p_batch_id, auth.uid());
end $function$;
-- qvm_new_apps.upload_batch_delete_data_run(p_batch_id bigint, p_actor uuid)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_delete_data_run(p_batch_id bigint, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_removed integer;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_b.status <> 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذه الدفعة لم تُنشر، فليس لها بيانات منشورة تُحذف', 'data', null);
  end if;

  v_removed := qvm_new_apps.upload_batch_clear_rows(p_batch_id);

  update qvm_new_apps.upload_batches set status = 'rolled_back', updated_at = now()
   where batch_id = p_batch_id;
  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (p_batch_id, 'delete_data',
          jsonb_build_object('removed', v_removed, 'template', v_b.template_key,
                             'file', v_b.file_name), p_actor);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('removed', v_removed));
end $function$;
-- qvm_new_apps.upload_batch_get(p_batch_id bigint, p_state text, p_limit integer, p_offset integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_get(p_batch_id bigint, p_state text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'batch', (select to_jsonb(b) from qvm_new_apps.upload_batches b where b.batch_id = p_batch_id),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'row_id', r.row_id, 'row_number', r.row_number,
               'source_part_number', r.source_part_number,
               'display_part_number', r.display_part_number,
               'clean_part_number', r.clean_part_number,
               'source_name', r.source_name, 'clean_name', r.clean_name,
               'brand', r.brand, 'part_class', r.part_class,
               'country_of_origin', r.country_of_origin,
               'matched_rule', (select rr.code || ' (' || rr.position || ')'
                                  from qvm_new_apps.upload_code_rules rr
                                 where rr.rule_id = r.matched_rule_id),
               'state', r.state, 'reason', r.reason, 'raw', r.raw)
             order by r.row_number)
        from (select * from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state)
               order by row_number limit p_limit offset p_offset) r), '[]'::jsonb),
    'shown', (select count(*) from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state))
  ));
end
$function$;
-- qvm_new_apps.upload_batch_publish(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_publish(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_written integer;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_b.status = 'published' then
    return jsonb_build_object('status', false, 'message', 'هذه الدفعة منشورة بالفعل', 'data', null);
  end if;

  v_written := qvm_new_apps.upload_batch_write_rows(p_batch_id);

  update qvm_new_apps.upload_batches
     set status = 'published', published_at = now(), updated_at = now()
   where batch_id = p_batch_id;
  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (p_batch_id, 'publish',
          jsonb_build_object('written', v_written, 'template', v_b.template_key), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('written', v_written,
      'still_disabled', (select count(*) from qvm_new_apps.upload_rows
                          where batch_id = p_batch_id and state = 'disabled')));
end
$function$;
-- qvm_new_apps.upload_batch_recompute(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_recompute(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  return qvm_new_apps.upload_batch_recompute_run(p_batch_id, auth.uid());
end $function$;
-- qvm_new_apps.upload_batch_recompute_run(p_batch_id bigint, p_actor uuid)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_recompute_run(p_batch_id bigint, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_r record; v_c jsonb; v_seen text[] := '{}'; v_state text; v_kept integer := 0;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  for v_r in select * from qvm_new_apps.upload_rows
              where batch_id = p_batch_id order by row_number loop

    if v_r.edited_at is not null then
      -- Someone fixed this row by hand. Re-deriving it would throw their work away.
      v_kept := v_kept + 1;
      v_state := v_r.state;
      if v_state <> 'rejected' and v_r.clean_part_number = any(v_seen) then
        v_state := 'duplicate';
      elsif v_state <> 'rejected' and v_r.clean_part_number is not null then
        v_seen := v_seen || v_r.clean_part_number;
      end if;
      if v_state is distinct from v_r.state then
        update qvm_new_apps.upload_rows set
          state = v_state,
          reason = case when v_state = 'duplicate' then 'مكرر داخل نفس الملف' else reason end
        where row_id = v_r.row_id;
      end if;
      continue;
    end if;

    v_c := qvm_new_apps.upload_clean_row(v_r.raw, v_b.template_key, v_b.source_kind, v_b.source_id);
    v_state := v_c->>'state';
    if v_state <> 'rejected' and (v_c->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state <> 'rejected' then
      v_seen := v_seen || (v_c->>'clean_part_number');
    end if;
    update qvm_new_apps.upload_rows set
      source_part_number = v_c->>'source_part_number',
      clean_part_number  = v_c->>'clean_part_number',
      display_part_number= v_c->>'display_part_number',
      clean_name         = v_c->>'clean_name',
      matched_rule_id    = nullif(v_c->>'matched_rule_id','')::bigint,
      brand              = v_c->>'brand',
      part_class         = v_c->>'part_class',
      country_of_origin  = v_c->>'country_of_origin',
      state              = v_state,
      reason             = case when v_state = 'duplicate' then 'مكرر داخل نفس الملف'
                                else v_c->>'reason' end
    where row_id = v_r.row_id;
  end loop;

  update qvm_new_apps.upload_batches b set
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = p_batch_id;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, changed_by)
  values (p_batch_id, 'recompute', p_actor);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) || jsonb_build_object('rows_kept_edited', v_kept)
               from qvm_new_apps.upload_batches b where b.batch_id = p_batch_id));
end $function$;
-- qvm_new_apps.upload_batch_reprocess(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_reprocess(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  return qvm_new_apps.upload_batch_reprocess_run(p_batch_id, auth.uid());
end $function$;
-- qvm_new_apps.upload_batch_reprocess_enqueue(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_reprocess_enqueue(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_job record;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  -- Refuse here rather than let the worker discover it minutes later, when nobody is watching.
  if v_b.status <> 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذه الدفعة غير منشورة — «إعادة الفحص» تكفي', 'data', null);
  end if;

  select * into v_job from qvm_new_apps.upload_jobs
   where batch_id = p_batch_id and status in ('queued','running');
  if v_job.job_id is not null then
    -- Already in hand. Handing back the existing job means the screen starts following that one
    -- instead of reporting an error for something that is going to happen anyway.
    return jsonb_build_object('status', true, 'message', 'already queued',
      'data', to_jsonb(v_job));
  end if;

  insert into qvm_new_apps.upload_jobs (batch_id, kind, requested_by)
  values (p_batch_id, 'reprocess', auth.uid())
  returning * into v_job;

  return jsonb_build_object('status', true, 'message', 'queued', 'data', to_jsonb(v_job));
end $function$;
-- qvm_new_apps.upload_batch_reprocess_run(p_batch_id bigint, p_actor uuid)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_reprocess_run(p_batch_id bigint, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_removed integer; v_written integer; v_before jsonb;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_b.status <> 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذه الدفعة غير منشورة — «إعادة الفحص» تكفي', 'data', null);
  end if;

  v_before := jsonb_build_object('ready', v_b.rows_ready, 'disabled', v_b.rows_disabled,
                                 'rejected', v_b.rows_rejected);

  v_removed := qvm_new_apps.upload_batch_clear_rows(p_batch_id);
  perform qvm_new_apps.upload_batch_recompute_run(p_batch_id, p_actor);
  v_written := qvm_new_apps.upload_batch_write_rows(p_batch_id);

  update qvm_new_apps.upload_batches
     set status = 'published', published_at = now(), updated_at = now()
   where batch_id = p_batch_id;

  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (p_batch_id, 'reprocess',
          jsonb_build_object('removed', v_removed, 'written', v_written,
                             'before', v_before,
                             'after', jsonb_build_object('ready', v_b.rows_ready,
                               'disabled', v_b.rows_disabled, 'rejected', v_b.rows_rejected)),
          p_actor);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('removed', v_removed, 'written', v_written,
      'rows_ready', v_b.rows_ready, 'rows_disabled', v_b.rows_disabled,
      'rows_rejected', v_b.rows_rejected));
end $function$;
-- qvm_new_apps.upload_batch_set_source(p_batch_id bigint, p_vendor_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_set_source(p_batch_id bigint, p_vendor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_name text;
  v_batch record;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_batch from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_batch.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  if p_vendor_id is null then
    update qvm_new_apps.upload_batches
       set source_kind = 'internal', source_id = null, source_label = null, updated_at = now()
     where batch_id = p_batch_id;
  else
    select v.vendor_name into v_name from qvm_new_apps.vendors v where v.vendor_id = p_vendor_id;
    if v_name is null then
      return jsonb_build_object('status', false, 'message', 'المورّد غير موجود', 'data', null);
    end if;
    update qvm_new_apps.upload_batches
       set source_kind = 'vendor', source_id = p_vendor_id, source_label = v_name, updated_at = now()
     where batch_id = p_batch_id;
  end if;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, changed_by)
  values (p_batch_id, 'set_source', auth.uid());

  -- Re-read the file against the newly attached vendor's code rules.
  return qvm_new_apps.upload_batch_recompute(p_batch_id);
end
$function$;
-- qvm_new_apps.upload_batch_stage(p_template_key text, p_file_name text, p_rows jsonb, p_source_kind text, p_source_id bigint, p_source_label text, p_branch_scope text, p_branch_ids bigint[])
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_stage(p_template_key text, p_file_name text, p_rows jsonb, p_source_kind text DEFAULT 'vendor'::text, p_source_id bigint DEFAULT NULL::bigint, p_source_label text DEFAULT NULL::text, p_branch_scope text DEFAULT 'all'::text, p_branch_ids bigint[] DEFAULT '{}'::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_batch bigint; v_row jsonb; v_clean jsonb; v_n integer := 0;
  v_seen text[] := '{}'; v_state text;
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text := p_source_kind; v_sid bigint := p_source_id; v_label text := p_source_label;
  v_ids bigint[] := coalesce(p_branch_ids, '{}');
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if not exists (select 1 from qvm_new_apps.upload_templates
                  where template_key = p_template_key and is_active
                    and (v_team or allowed_for_vendor)) then
    return jsonb_build_object('status', false,
      'message', case when v_team then 'نوع ملف غير معروف'
                      else 'هذا النوع من الملفات لا يرفعه المورد' end, 'data', null);
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('status', false, 'message', 'الملف لا يحتوي على صفوف', 'data', null);
  end if;

  -- A vendor writes as themselves whatever the request said. Trusting the
  -- caller here would let one supplier file stock under another's name, and
  -- the code rules are keyed on that name.
  if not v_team then
    v_kind := 'vendor';
    v_sid := v_vendor;
    select vendor_name into v_label from qvm_new_apps.vendors where vendor_id = v_vendor;
    -- Same for branches: only their own, and silently dropping someone else's
    -- id is safer than failing on it.
    v_ids := coalesce((select array_agg(b.vendor_branch_id)
                         from qvm_new_apps.vendor_branches b
                        where b.vendor_id = v_vendor and b.vendor_branch_id = any(v_ids)), '{}');
    if p_branch_scope = 'specific' and array_length(v_ids, 1) is null then
      return jsonb_build_object('status', false,
        'message', 'لم تُختَر فروع تخصّك', 'data', null);
    end if;
  end if;

  insert into qvm_new_apps.upload_batches
    (template_key, file_name, source_kind, source_id, source_label,
     branch_scope, branch_ids, status, uploaded_by)
  values (p_template_key, p_file_name, v_kind, v_sid, v_label,
          p_branch_scope, v_ids, 'preview', auth.uid())
  returning batch_id into v_batch;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_clean := qvm_new_apps.upload_clean_row(v_row, p_template_key, v_kind, v_sid);
    v_state := v_clean->>'state';
    if v_state <> 'rejected' and (v_clean->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state <> 'rejected' then
      v_seen := v_seen || (v_clean->>'clean_part_number');
    end if;

    insert into qvm_new_apps.upload_rows
      (batch_id, row_number, raw, source_part_number, clean_part_number,
       display_part_number, source_name, clean_name, matched_rule_id, brand,
       part_class, country_of_origin, state, reason)
    values (v_batch, v_n, v_row,
            v_clean->>'source_part_number', v_clean->>'clean_part_number',
            v_clean->>'display_part_number',
            v_clean->>'source_name', v_clean->>'clean_name',
            nullif(v_clean->>'matched_rule_id', '')::bigint,
            v_clean->>'brand', v_clean->>'part_class', v_clean->>'country_of_origin',
            v_state,
            case when v_state = 'duplicate' then 'مكرر داخل نفس الملف'
                 else v_clean->>'reason' end);
  end loop;

  update qvm_new_apps.upload_batches b set
    rows_total     = v_n,
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = v_batch;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (v_batch, 'stage', jsonb_build_object('file', p_file_name, 'rows', v_n), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) from qvm_new_apps.upload_batches b where b.batch_id = v_batch));
end
$function$;
-- qvm_new_apps.upload_batch_write_rows(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_write_rows(p_batch_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_written integer := 0; v_extra integer := 0; v_branches bigint[];
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then return 0; end if;

  -- One entry per branch the file covers; a single null when it covers all.
  v_branches := case
    when v_b.branch_scope = 'specific' and coalesce(array_length(v_b.branch_ids, 1), 0) > 0
    then v_b.branch_ids else array[null]::bigint[] end;

  if v_b.template_key = 'agency_price_list' then
    insert into qvm_new_apps.agency_price_reference
      (source_part_number, clean_part_number, source_name, clean_name, brand,
       agency_price, effective_from, source_label, batch_id)
    select r.source_part_number, r.clean_part_number, r.source_name, r.clean_name, r.brand,
           (r.raw->>'agency_price')::numeric, nullif(r.raw->>'effective_from','')::date,
           coalesce(v_b.source_label, 'agency'), v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (clean_part_number, lower(source_label)) do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      brand = excluded.brand, agency_price = excluded.agency_price,
      effective_from = excluded.effective_from,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_on_hand' then
    insert into qvm_new_apps.inventory_stock
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, brand, part_class, country_of_origin,
       quantity, is_available, wholesale_price, retail_price, before_discount_price,
       claimed_agency_price, claimed_agency_price_after_discount,
       dealer_agency_discount_pct, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.brand, r.part_class, r.country_of_origin,
           case when r.raw->>'qty' ~ '^[0-9]+$' then (r.raw->>'qty')::integer else null end,
           coalesce(lower(btrim(r.raw->>'qty')) not in ('0','notavailable','not available','غير متوفر'), true),
           nullif(r.raw->>'wholesale_price','')::numeric,
           nullif(r.raw->>'retail_price','')::numeric,
           nullif(r.raw->>'before_discount_price','')::numeric,
           nullif(r.raw->>'agency_price','')::numeric,
           nullif(r.raw->>'agency_price_after_discount','')::numeric,
           nullif(r.raw->>'dealer_agency_discount_pct','')::numeric,
           v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1), clean_part_number)
    do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      brand = excluded.brand, part_class = excluded.part_class,
      country_of_origin = excluded.country_of_origin,
      quantity = excluded.quantity, is_available = excluded.is_available,
      wholesale_price = excluded.wholesale_price, retail_price = excluded.retail_price,
      before_discount_price = excluded.before_discount_price,
      claimed_agency_price = excluded.claimed_agency_price,
      claimed_agency_price_after_discount = excluded.claimed_agency_price_after_discount,
      dealer_agency_discount_pct = excluded.dealer_agency_discount_pct,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'past_purchases' then
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, cost, cost_on, source_cost_date,
       supplier_name, brand, brand_class, origin, batch_id)
    select r.source_part_number, r.clean_part_number,
           (r.raw->>'unit_price')::double precision,
           nullif(r.raw->>'purchase_date','')::date, r.raw->>'purchase_date',
           r.raw->>'supplier_name', r.brand, r.part_class, 'external_excel', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and not exists (
         select 1 from qvm_new_apps.part_purchase_history h
          where h.clean_part_number = r.clean_part_number
            and coalesce(h.supplier_name,'') = coalesce(r.raw->>'supplier_name','')
            and h.cost_on is not distinct from nullif(r.raw->>'purchase_date','')::date
            and h.cost is not distinct from (r.raw->>'unit_price')::double precision);
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'aliases' then
    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select r.clean_part_number, qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'),
           r.source_part_number, r.raw->>'alias_part_number', r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_written = row_count;

    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'), r.clean_part_number,
           r.raw->>'alias_part_number', r.source_part_number, r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_extra = row_count;
    v_written := v_written + v_extra;

  elsif v_b.template_key = 'offers' then
    insert into qvm_new_apps.part_offers
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       offer_price, starts_on, ends_on, qty_limit, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number,
           (r.raw->>'offer_price')::numeric,
           (r.raw->>'starts_on')::date, (r.raw->>'ends_on')::date,
           nullif(r.raw->>'qty_limit','')::integer, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'group_import_request' then
    insert into qvm_new_apps.group_import_requests
      (source_part_number, clean_part_number, source_name, clean_name, qty,
       target_price, origin_country, payment_terms, arrival_weeks, batch_id)
    select r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           (r.raw->>'qty')::integer, nullif(r.raw->>'target_price','')::numeric,
           r.raw->>'origin_country', r.raw->>'payment_terms',
           nullif(r.raw->>'arrival_weeks','')::integer, v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_auction' then
    insert into qvm_new_apps.stock_auction_items
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, qty, part_class, reserve_price, closes_on, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           (r.raw->>'qty')::integer, r.part_class,
           nullif(r.raw->>'reserve_price','')::numeric,
           nullif(r.raw->>'closes_on','')::date, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  else
    raise exception 'نوع ملف غير مدعوم للنشر: %', v_b.template_key;
  end if;

  return v_written;
end
$function$;
-- qvm_new_apps.upload_clean_row(p_raw jsonb, p_template_key text, p_source_kind text, p_source_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_clean_row(p_raw jsonb, p_template_key text, p_source_kind text, p_source_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_pn_raw   text := nullif(btrim(coalesce(p_raw->>'part_number', '')), '');
  -- name_ar first: this is a Saudi catalogue and the Arabic name is the one staff read.
  v_name_raw text := coalesce(
                       nullif(btrim(coalesce(p_raw->>'name_ar', '')), ''),
                       nullif(btrim(coalesce(p_raw->>'name_en', '')), ''),
                       nullif(btrim(coalesce(p_raw->>'description', '')), ''));
  v_name_out text;
  v_pn_norm  text; v_work text; v_probe text; v_stripped text;
  v_rule record; v_code text;
  v_missing text[] := '{}'; v_col jsonb;
  v_class text := nullif(btrim(coalesce(p_raw->>'part_class', '')), '');
  v_unknown boolean; v_cut integer; v_key text;
begin
  for v_col in
    select c from qvm_new_apps.upload_templates t,
                  lateral jsonb_array_elements(t.columns) c
     where t.template_key = p_template_key and (c->>'required')::boolean
  loop
    if nullif(btrim(coalesce(p_raw->>(v_col->>'key'), '')), '') is null then
      v_missing := v_missing || (v_col->>'key');
    end if;
  end loop;

  if array_length(v_missing, 1) is not null then
    return jsonb_build_object(
      'state', 'rejected',
      'reason', 'حقول مطلوبة ناقصة: ' || array_to_string(v_missing, '، '),
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', null, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'matched_rule_id', null, 'brand', null, 'part_class', null, 'country_of_origin', null);
  end if;

  v_pn_norm := qvm_new_apps.normalize_part_number(v_pn_raw);
  if v_pn_norm is null then
    return jsonb_build_object(
      'state', 'rejected', 'reason', 'رقم القطعة لا يحتوي على حروف أو أرقام',
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', null, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'matched_rule_id', null, 'brand', null, 'part_class', null, 'country_of_origin', null);
  end if;

  select r.*, qvm_new_apps.normalize_part_number(r.code) as norm_code into v_rule
    from qvm_new_apps.upload_code_rules r
   where r.source_kind = p_source_kind
     and coalesce(r.source_id, -1) = coalesce(p_source_id, -1)
     and qvm_new_apps.normalize_part_number(r.code) is not null
     and ( (r.position = 'prefix'
            and v_pn_norm like qvm_new_apps.normalize_part_number(r.code) || '%')
        or (r.position = 'suffix'
            and v_pn_norm like '%' || qvm_new_apps.normalize_part_number(r.code)) )
   order by length(qvm_new_apps.normalize_part_number(r.code)) desc
   limit 1;

  -- The part number with the matched code taken off, whatever the treatment.
  -- Used only to decide whether anything *else* is still unexplained.
  v_stripped := v_pn_raw;
  if v_rule.rule_id is not null then
    v_code := v_rule.norm_code;
    if v_rule.position = 'prefix' then
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(left(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(substr(v_pn_raw, v_cut + 2), '-_. ');
    else
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(right(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(left(v_pn_raw, length(v_pn_raw) - v_cut - 1), '-_. ');
    end if;
    if coalesce(v_stripped, '') = '' then v_stripped := v_pn_raw; end if;
  end if;

  -- What is actually stored: stripped only when the rule says to strip.
  v_work  := case when v_rule.rule_id is not null and v_rule.treatment = 'strip'
                  then v_stripped else v_pn_raw end;
  v_probe := case when v_rule.rule_id is not null then v_stripped else v_pn_raw end;

  v_key := qvm_new_apps.normalize_part_number(v_work);
  if v_key is null then
    return jsonb_build_object(
      'state', 'rejected',
      'reason', 'لم يتبقَّ رقم بعد تطبيق قاعدة الكود — راجع القاعدة',
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', v_work, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'matched_rule_id', v_rule.rule_id, 'brand', null, 'part_class', null,
      'country_of_origin', null);
  end if;

  -- The dictionary only ever fills a gap; a name the supplier did send always wins, because they
  -- are the ones who have the part in front of them.
  v_name_out := v_name_raw;
  if v_name_out is null then
    select d.name into v_name_out
      from qvm_new_apps.part_name_dictionary d
     where d.clean_part_number = v_key;
  end if;

  v_unknown := v_probe ~ '^[A-Za-z]{1,4}[-_. ]'
            or v_probe ~ '[-_. ][A-Za-z]{1,4}$'
            or (v_rule.rule_id is null and v_probe ~ '^[A-Za-z]{1,4}[0-9]{4,}$');

  return jsonb_build_object(
    'state',  case when v_unknown then 'disabled' else 'ready' end,
    'reason', case when v_unknown
                   then 'أضِف قاعدة كود لهذه البادئة أو اللاحقة ثم اربطها لتفعيل الصنف'
                   else null end,
    'source_part_number',  v_pn_raw,
    'display_part_number', v_work,
    'clean_part_number',   v_key,
    'source_name', v_name_raw, 'clean_name', v_name_out,
    'matched_rule_id', v_rule.rule_id,
    'brand', coalesce(v_rule.brand, nullif(btrim(coalesce(p_raw->>'make', '')), '')),
    'part_class', coalesce(v_rule.part_class, v_class),
    'country_of_origin', v_rule.country_of_origin);
end
$function$;
-- qvm_new_apps.upload_code_rule_impact(p_rule_id bigint, p_source_kind text, p_source_id bigint, p_code text, p_position text)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_code_rule_impact(p_rule_id bigint DEFAULT NULL::bigint, p_source_kind text DEFAULT NULL::text, p_source_id bigint DEFAULT NULL::bigint, p_code text DEFAULT NULL::text, p_position text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_kind text; v_sid bigint; v_code text; v_pos text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if p_rule_id is not null then
    select source_kind, source_id, code, position into v_kind, v_sid, v_code, v_pos
      from qvm_new_apps.upload_code_rules where rule_id = p_rule_id;
  else
    v_kind := coalesce(p_source_kind, 'vendor'); v_sid := p_source_id;
    v_code := p_code; v_pos := p_position;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'affected', (
      select count(*) from qvm_new_apps.upload_rows u
        join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
       where b.source_kind = v_kind
         and coalesce(b.source_id, -1) = coalesce(v_sid, -1)
         and ( (v_pos = 'prefix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                  like qvm_new_apps.normalize_part_number(v_code) || '%')
            or (v_pos = 'suffix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                  like '%' || qvm_new_apps.normalize_part_number(v_code)) )),
    'published_affected', (
      select count(*) from qvm_new_apps.upload_rows u
        join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
       where b.status = 'published'
         and b.source_kind = v_kind
         and coalesce(b.source_id, -1) = coalesce(v_sid, -1)
         and ( (v_pos = 'prefix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                  like qvm_new_apps.normalize_part_number(v_code) || '%')
            or (v_pos = 'suffix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                  like '%' || qvm_new_apps.normalize_part_number(v_code)) )),
    'sample', coalesce((
      select jsonb_agg(jsonb_build_object(
               'source_part_number', s.source_part_number,
               'before', s.display_part_number,
               'state_before', s.state, 'file', s.file_name))
        from (select u.source_part_number, u.display_part_number, u.state, b.file_name
                from qvm_new_apps.upload_rows u
                join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
               where b.source_kind = v_kind
                 and coalesce(b.source_id, -1) = coalesce(v_sid, -1)
                 and ( (v_pos = 'prefix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                          like qvm_new_apps.normalize_part_number(v_code) || '%')
                    or (v_pos = 'suffix' and qvm_new_apps.normalize_part_number(u.source_part_number)
                          like '%' || qvm_new_apps.normalize_part_number(v_code)) )
               limit 5) s), '[]'::jsonb)
  ));
end
$function$;
-- qvm_new_apps.upload_code_rule_save(p_rule_id bigint, p_patch jsonb, p_confirm boolean, p_reprocess_published boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_code_rule_save(p_rule_id bigint, p_patch jsonb, p_confirm boolean DEFAULT false, p_reprocess_published boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_id bigint; v_before jsonb; v_impact jsonb; v_b bigint; v_class text;
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text; v_sid bigint; v_label text; v_reprocessed integer := 0;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_patch->>'code','')), '') is null then
    return jsonb_build_object('status', false, 'message', 'الكود مطلوب', 'data', null);
  end if;

  v_class := lower(coalesce(p_patch->>'part_class', ''));
  if v_class in ('original', 'genuine')
     and nullif(btrim(coalesce(p_patch->>'country_of_origin','')), '') is not null then
    return jsonb_build_object('status', false,
      'message', 'القطعة الأصلية ليس لها بلد صنع في هذا النظام', 'data', null);
  end if;

  if v_team then
    v_kind := coalesce(p_patch->>'source_kind','vendor');
    v_sid := nullif(p_patch->>'source_id','')::bigint;
    v_label := nullif(btrim(coalesce(p_patch->>'source_label','')), '');
  else
    v_kind := 'vendor'; v_sid := v_vendor;
    select vendor_name into v_label from qvm_new_apps.vendors where vendor_id = v_vendor;
  end if;

  if p_rule_id is not null then
    select to_jsonb(r) into v_before from qvm_new_apps.upload_code_rules r
     where r.rule_id = p_rule_id
       and (v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor));
    if v_before is null then
      return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
    end if;
    v_impact := qvm_new_apps.upload_code_rule_impact(p_rule_id);
    if not p_confirm then
      return jsonb_build_object('status', false, 'message', 'needs_confirmation',
        'data', v_impact->'data');
    end if;

    update qvm_new_apps.upload_code_rules r set
      code = btrim(p_patch->>'code'),
      position = coalesce(p_patch->>'position', r.position),
      treatment = coalesce(p_patch->>'treatment', r.treatment),
      brand = nullif(btrim(coalesce(p_patch->>'brand','')), ''),
      part_class = coalesce(nullif(btrim(coalesce(p_patch->>'part_class','')), ''), r.part_class),
      country_of_origin = nullif(btrim(coalesce(p_patch->>'country_of_origin','')), ''),
      updated_at = now()
    where r.rule_id = p_rule_id;
    v_id := p_rule_id;
  else
    insert into qvm_new_apps.upload_code_rules
      (source_kind, source_id, source_label, code, position, treatment,
       brand, part_class, country_of_origin, created_by)
    values (v_kind, v_sid, v_label, btrim(p_patch->>'code'),
            coalesce(p_patch->>'position','prefix'),
            coalesce(p_patch->>'treatment','strip'),
            nullif(btrim(coalesce(p_patch->>'brand','')), ''),
            coalesce(nullif(btrim(coalesce(p_patch->>'part_class','')), ''), 'commercial'),
            nullif(btrim(coalesce(p_patch->>'country_of_origin','')), ''),
            auth.uid())
    returning rule_id into v_id;
  end if;

  -- Unpublished batches always follow: nothing of theirs is live, so there is
  -- nothing to decide.
  for v_b in
    select b.batch_id from qvm_new_apps.upload_batches b
     join qvm_new_apps.upload_code_rules r on r.rule_id = v_id
    where b.source_kind = r.source_kind
      and coalesce(b.source_id, -1) = coalesce(r.source_id, -1)
      and b.status <> 'published'
  loop
    perform qvm_new_apps.upload_batch_recompute(v_b);
  end loop;

  if p_reprocess_published then
    for v_b in
      select b.batch_id from qvm_new_apps.upload_batches b
       join qvm_new_apps.upload_code_rules r on r.rule_id = v_id
      where b.source_kind = r.source_kind
        and coalesce(b.source_id, -1) = coalesce(r.source_id, -1)
        and b.status = 'published'
    loop
      perform qvm_new_apps.upload_batch_reprocess(v_b);
      v_reprocessed := v_reprocessed + 1;
    end loop;
  end if;

  insert into qvm_new_apps.upload_batch_log (action, detail, changed_by)
  values (case when p_rule_id is null then 'rule_create' else 'rule_update' end,
          jsonb_build_object('rule_id', v_id, 'before', v_before,
                             'reprocessed_batches', v_reprocessed,
                             'after', (select to_jsonb(r) from qvm_new_apps.upload_code_rules r
                                        where r.rule_id = v_id)),
          auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('rule_id', v_id, 'reprocessed_batches', v_reprocessed));
end
$function$;
-- qvm_new_apps.upload_delete_decide(p_request_id bigint, p_approve boolean, p_note text)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_delete_decide(p_request_id bigint, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_req record; v_res jsonb; v_removed integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Locked so two approvers clicking at once cannot both run the deletion.
  select * into v_req from qvm_new_apps.upload_delete_requests
   where request_id = p_request_id for update;
  if v_req.request_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_req.status <> 'pending' then
    return jsonb_build_object('status', false, 'message', 'هذا الطلب مُبتّ فيه بالفعل', 'data', null);
  end if;

  if not p_approve then
    update qvm_new_apps.upload_delete_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
     where request_id = p_request_id;
    return jsonb_build_object('status', true, 'message', 'rejected', 'data',
      (select to_jsonb(r) from qvm_new_apps.upload_delete_requests r where r.request_id = p_request_id));
  end if;

  -- The deletion is credited to the person who approved it, not to the one who asked: approving is
  -- the act that removed the data.
  v_res := qvm_new_apps.upload_batch_delete_data_run(v_req.batch_id, auth.uid());
  if not coalesce((v_res->>'status')::boolean, false) then
    return v_res;   -- nothing was deleted, so the request stays open
  end if;
  v_removed := (v_res->'data'->>'removed')::integer;

  update qvm_new_apps.upload_delete_requests
     set status = 'approved', decided_by = auth.uid(), decided_at = now(),
         decision_note = p_note, rows_removed = v_removed
   where request_id = p_request_id;

  return jsonb_build_object('status', true, 'message', 'approved', 'data',
    (select to_jsonb(r) from qvm_new_apps.upload_delete_requests r where r.request_id = p_request_id));
end $function$;
-- qvm_new_apps.upload_delete_request(p_batch_id bigint, p_reason text)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_delete_request(p_batch_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_b record; v_req record;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_b.status <> 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذه الدفعة لم تُنشر، فليس لها بيانات منشورة تُحذف', 'data', null);
  end if;

  select * into v_req from qvm_new_apps.upload_delete_requests
   where batch_id = p_batch_id and status = 'pending';
  if v_req.request_id is not null then
    return jsonb_build_object('status', true, 'message', 'already pending', 'data', to_jsonb(v_req));
  end if;

  insert into qvm_new_apps.upload_delete_requests (batch_id, reason, requested_by)
  values (p_batch_id, nullif(btrim(p_reason), ''), auth.uid())
  returning * into v_req;

  return jsonb_build_object('status', true, 'message', 'pending', 'data', to_jsonb(v_req));
end $function$;
-- qvm_new_apps.upload_job_get(p_batch_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_job_get(p_batch_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_job record;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_job from qvm_new_apps.upload_jobs
   where batch_id = p_batch_id
   order by requested_at desc limit 1;
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', case when v_job.job_id is null then null else to_jsonb(v_job) end);
end $function$;
-- qvm_new_apps.upload_jobs_run_next()
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_jobs_run_next()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_job record; v_res jsonb;
begin
  -- SKIP LOCKED so two overlapping runs never take the same job.
  select * into v_job from qvm_new_apps.upload_jobs
   where status = 'queued'
   order by requested_at
   for update skip locked
   limit 1;

  if v_job.job_id is null then
    return jsonb_build_object('status', true, 'message', 'idle', 'data', null);
  end if;

  update qvm_new_apps.upload_jobs
     set status = 'running', started_at = now(), attempts = attempts + 1
   where job_id = v_job.job_id;

  begin
    v_res := qvm_new_apps.upload_batch_reprocess_run(v_job.batch_id, v_job.requested_by);

    if coalesce((v_res->>'status')::boolean, false) then
      update qvm_new_apps.upload_jobs
         set status = 'done', finished_at = now(), result = v_res->'data', error = null
       where job_id = v_job.job_id;
    else
      -- A business refusal is a finished job, not a crash: retrying it would refuse again.
      update qvm_new_apps.upload_jobs
         set status = 'failed', finished_at = now(), error = v_res->>'message'
       where job_id = v_job.job_id;
    end if;
  exception when others then
    -- The row work is rolled back by the failed sub-block; recording why is the point of the
    -- handler, so the operator sees a reason instead of a job stuck on "running" forever.
    update qvm_new_apps.upload_jobs
       set status = 'failed', finished_at = now(), error = sqlerrm
     where job_id = v_job.job_id;
  end;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(j) from qvm_new_apps.upload_jobs j where j.job_id = v_job.job_id));
end $function$;
-- qvm_new_apps.upload_page_get()
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_page_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(

    'is_vendor', not v_team,
    'vendor_id', v_vendor,

    'templates', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where t.is_active and (v_team or t.allowed_for_vendor)), '[]'::jsonb),

    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rule_id', r.rule_id, 'source_kind', r.source_kind,
               'source_id', r.source_id, 'source_label', r.source_label,
               'code', r.code, 'position', r.position, 'treatment', r.treatment,
               'brand', r.brand, 'part_class', r.part_class,
               'country_of_origin', r.country_of_origin, 'created_at', r.created_at,
               'linked', (select count(*) from qvm_new_apps.upload_rows u
                           where u.matched_rule_id = r.rule_id),
               'unlinked', (select count(*) from qvm_new_apps.upload_rows u
                             join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
                            where b.source_kind = r.source_kind
                              and coalesce(b.source_id, -1) = coalesce(r.source_id, -1)
                              and u.state = 'disabled'))
             order by r.source_label, r.code)
        from qvm_new_apps.upload_code_rules r
       where v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor)), '[]'::jsonb),

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'file_name', b.file_name, 'status', b.status,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate,
               'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where qvm_new_apps.is_qparts_team()
                  or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id())
               order by created_at desc limit 50) b
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'totals', (select jsonb_build_object(
                 'accepted', coalesce(sum(rows_ready), 0),
                 'failed', coalesce(sum(rows_rejected), 0))
                 from qvm_new_apps.upload_batches b
                where v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)),

    'options', jsonb_build_object(
      -- A vendor picks nothing: they are the source, and their own branches
      -- are the only ones on offer.
      'vendors', coalesce((select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
                                   order by v.vendor_name)
                             from qvm_new_apps.vendors v
                            where v_team or v.vendor_id = v_vendor), '[]'::jsonb),
      'vendor_branches', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', vb.vendor_branch_id, 'vendor_id', vb.vendor_id,
                             'name', coalesce(vb.branch_name, ''), 'city', vb.city)
                           order by vb.branch_name)
                             from qvm_new_apps.vendor_branches vb
                            where coalesce(vb.is_active, true)
                              and (v_team or vb.vendor_id = v_vendor)), '[]'::jsonb),
      'part_classes', jsonb_build_array(
        jsonb_build_object('key','genuine','label_en','Genuine','label_ar','أصلي'),
        jsonb_build_object('key','oem','label_en','OEM','label_ar','OEM'),
        jsonb_build_object('key','commercial','label_en','Commercial','label_ar','تجاري'),
        jsonb_build_object('key','used','label_en','Used','label_ar','مستعمل'))
    )
  ));
end
$function$;
-- qvm_new_apps.upload_row_update(p_row_id bigint, p_patch jsonb)
CREATE OR REPLACE FUNCTION qvm_new_apps.upload_row_update(p_row_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_row record;
  v_clean text;
  v_state text;
begin
  select r.*, b.batch_id as b_batch_id into v_row
    from qvm_new_apps.upload_rows r
    join qvm_new_apps.upload_batches b on b.batch_id = r.batch_id
   where r.row_id = p_row_id;

  if v_row.row_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if not qvm_new_apps.may_touch_upload_batch(v_row.b_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Presence semantics, not COALESCE: a key that is present and null means "clear this", which is
  -- the only way to remove a wrong brand or country. A key that is absent means "leave it".
  v_clean := case when p_patch ? 'clean_part_number'
                  then qvm_new_apps.normalize_part_number(nullif(btrim(p_patch->>'clean_part_number'), ''))
                  else v_row.clean_part_number end;

  -- The clean part number is the key every live table is written against; a row without one has
  -- nothing to attach to, so it is refused rather than saved into a broken state.
  if v_clean is null then
    return jsonb_build_object('status', false,
      'message', 'رقم القطعة النظيف مطلوب — لا يمكن حفظ صف بدونه', 'data', null);
  end if;

  v_state := case when p_patch ? 'state' then p_patch->>'state' else v_row.state end;
  if v_state not in ('ready', 'disabled', 'rejected', 'duplicate') then
    return jsonb_build_object('status', false, 'message', 'حالة غير معروفة: ' || v_state, 'data', null);
  end if;

  update qvm_new_apps.upload_rows r set
    clean_part_number   = v_clean,
    display_part_number = case when p_patch ? 'display_part_number'
                               then nullif(btrim(p_patch->>'display_part_number'), '')
                               else r.display_part_number end,
    clean_name          = case when p_patch ? 'clean_name'
                               then nullif(btrim(p_patch->>'clean_name'), '') else r.clean_name end,
    brand               = case when p_patch ? 'brand'
                               then nullif(btrim(p_patch->>'brand'), '') else r.brand end,
    part_class          = case when p_patch ? 'part_class'
                               then nullif(btrim(p_patch->>'part_class'), '') else r.part_class end,
    country_of_origin   = case when p_patch ? 'country_of_origin'
                               then nullif(btrim(p_patch->>'country_of_origin'), '') else r.country_of_origin end,
    state               = v_state,
    -- The reason describes what the cleanup wanted fixed. Once a person has fixed it, leaving the
    -- old complaint on screen next to a good row is just noise.
    reason              = case when v_state = 'ready' then null else r.reason end,
    edited_at           = now(),
    edited_by           = auth.uid()
  where r.row_id = p_row_id;

  update qvm_new_apps.upload_batches b set
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = v_row.b_batch_id;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, changed_by)
  values (v_row.b_batch_id, 'row_edit', auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(r) from qvm_new_apps.upload_rows r where r.row_id = p_row_id));
end
$function$;
-- qvm_new_apps.uploaded_data_get(p_template_key text, p_status text, p_search text, p_limit integer, p_offset integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.uploaded_data_get(p_template_key text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'is_team', v_team,

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'template_label', tpl.label_ar, 'file_name', b.file_name,
               'status', b.status, 'source_kind', b.source_kind,
               'source_id', b.source_id,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate, 'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at,
               'delete_request', (
                 select jsonb_build_object('request_id', r.request_id, 'status', r.status,
                                           'reason', r.reason, 'requested_at', r.requested_at,
                                           'requested_by_name', ru.user_name)
                   from qvm_new_apps.upload_delete_requests r
                   left join qvm_new_apps.user_data ru on ru.user_id = r.requested_by
                  where r.batch_id = b.batch_id and r.status = 'pending'
                  limit 1),
               'live_rows', case b.template_key
                 when 'agency_price_list' then (select count(*) from qvm_new_apps.agency_price_reference x where x.batch_id = b.batch_id)
                 when 'stock_on_hand'     then (select count(*) from qvm_new_apps.inventory_stock x where x.batch_id = b.batch_id)
                 when 'past_purchases'    then (select count(*) from qvm_new_apps.part_purchase_history x where x.batch_id = b.batch_id)
                 when 'aliases'           then (select count(*) from qvm_new_apps.part_aliases x where x.batch_id = b.batch_id)
                 when 'offers'            then (select count(*) from qvm_new_apps.part_offers x where x.batch_id = b.batch_id)
                 when 'group_import_request' then (select count(*) from qvm_new_apps.group_import_requests x where x.batch_id = b.batch_id)
                 when 'stock_auction'     then (select count(*) from qvm_new_apps.stock_auction_items x where x.batch_id = b.batch_id)
                 else 0 end)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where (p_template_key is null or template_key = p_template_key)
                 and (p_status is null or status = p_status)
                 and (p_search is null or file_name ilike '%' || p_search || '%'
                      or coalesce(source_label,'') ilike '%' || p_search || '%')
                 and (qvm_new_apps.is_qparts_team()
                      or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id()))
               order by created_at desc limit p_limit offset p_offset) b
        join qvm_new_apps.upload_templates tpl on tpl.template_key = b.template_key
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'total', (select count(*) from qvm_new_apps.upload_batches b
               where (p_template_key is null or b.template_key = p_template_key)
                 and (p_status is null or b.status = p_status)
                 and (p_search is null or b.file_name ilike '%' || p_search || '%'
                      or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'counters', (select jsonb_build_object(
        'files', count(*), 'accepted', coalesce(sum(rows_ready), 0),
        'rejected', coalesce(sum(rows_rejected), 0),
        'awaiting_rule', coalesce(sum(rows_disabled), 0))
        from qvm_new_apps.upload_batches b
       where v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)),

    'pending_deletes', (select count(*) from qvm_new_apps.upload_delete_requests r
                         join qvm_new_apps.upload_batches b on b.batch_id = r.batch_id
                        where r.status = 'pending'
                          and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'vendors', case when v_team then coalesce((
        select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
               order by v.vendor_name)
          from qvm_new_apps.vendors v), '[]'::jsonb) else '[]'::jsonb end,

    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'template_key', t.template_key, 'label_ar', t.label_ar,
               'files', (select count(*) from qvm_new_apps.upload_batches b
                          where b.template_key = t.template_key
                            and (p_status is null or b.status = p_status)
                            and (p_search is null or b.file_name ilike '%' || p_search || '%'
                                 or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                            and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))))
             order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where v_team or t.allowed_for_vendor), '[]'::jsonb)
  ));
end
$function$;
-- qvm_new_apps.wa_avatars_pending(p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_avatars_pending(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb;
BEGIN
  -- Never checked, or last checked over a week ago. Claim by stamping the
  -- check time up front so a slow fetch is not retried on the next pass.
  WITH picked AS (
    SELECT wa_contact_id, phone_e164
      FROM qvm_new_apps.wa_contacts
     WHERE avatar_checked_at IS NULL
        OR avatar_checked_at < now() - interval '7 days'
     ORDER BY avatar_checked_at NULLS FIRST
     LIMIT GREATEST(COALESCE(p_limit, 5), 1)
     FOR UPDATE SKIP LOCKED
  ), stamped AS (
    UPDATE qvm_new_apps.wa_contacts c
       SET avatar_checked_at = now()
      FROM picked p
     WHERE c.wa_contact_id = p.wa_contact_id
    RETURNING c.wa_contact_id, c.phone_e164, c.avatar_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) INTO v FROM stamped s;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', v);
END;
$function$;
-- qvm_new_apps.wa_check_passcode(p_code text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_check_passcode(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_expected text;
BEGIN
  -- Not even a wrong-code attempt is answered for non-staff.
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT value INTO v_expected
    FROM qvm_new_apps.wa_settings WHERE key = 'inbox_passcode_sha256';

  -- No code configured means the screen is simply open.
  IF v_expected IS NULL THEN
    RETURN jsonb_build_object('status', true, 'message', 'ok',
      'data', jsonb_build_object('ok', true, 'required', false));
  END IF;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object(
      'ok', encode(extensions.digest(COALESCE(p_code, ''), 'sha256'), 'hex') = lower(v_expected),
      'required', true));
END;
$function$;
-- qvm_new_apps.wa_claim_outbox(p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_claim_outbox(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_rows jsonb;
begin
  with picked as (
    select distinct on (o.thread_id) o.outbox_id
      from qvm_new_apps.wa_outbox o
     where o.status = 'queued' and o.next_attempt_at <= now()
       and not exists (select 1 from qvm_new_apps.wa_outbox s
                        where s.thread_id = o.thread_id and s.status = 'sending')
     order by o.thread_id, o.outbox_id
  ), capped as (
    select outbox_id from picked order by outbox_id
     limit greatest(coalesce(p_limit, 10), 1)
  ), locked as (
    select o.outbox_id from qvm_new_apps.wa_outbox o
      join capped c on c.outbox_id = o.outbox_id
     where o.status = 'queued' for update of o skip locked
  ), claimed as (
    update qvm_new_apps.wa_outbox o
       set status = 'sending', attempts = o.attempts + 1, updated_at = now()
      from locked l where o.outbox_id = l.outbox_id
    returning o.outbox_id, o.message_id, o.thread_id, o.to_phone, o.body,
              o.media_url, o.media_mime, o.media_kind, o.media_name, o.attempts,
              o.kind, o.target_wa_message_id, o.reply_to_wa_id,
              o.channel, o.to_email, o.subject, o.email_account_id
  )
  select coalesce(jsonb_agg(to_jsonb(c) order by c.outbox_id), '[]'::jsonb) into v_rows from claimed c;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v_rows);
end
$function$;
-- qvm_new_apps.wa_compare_offers(p_quotation_id integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_compare_offers(p_quotation_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order jsonb; v_vendors jsonb; v_rows jsonb;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select to_jsonb(x) into v_order from (
    select q.quotation_id, q.order_number, q.plate_number, q.created_at
      from qvm_new_apps.quotations q where q.quotation_id = p_quotation_id) x;
  if v_order is null then
    return jsonb_build_object('status', false, 'message', 'order not found', 'data', null);
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.vendor_name), '[]'::jsonb) into v_vendors
    from (
      select distinct qv.vendor_id, v.vendor_name, qv.vendor_status
        from qvm_new_apps.quotation_vendors qv
        left join qvm_new_apps.vendors v on v.vendor_id = qv.vendor_id
       where qv.quotation_id = p_quotation_id) x;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.quotation_item_id), '[]'::jsonb) into v_rows
    from (
      select
        qi.quotation_item_id, qi.part_number, qi.part_description,
        qi.quantity, qi.item_status,
        case when nullif(btrim(qi.part_number), '') is null then null else (
          select min(h.cost)
            from qvm_new_apps.quotation_vendor_items h
            join qvm_new_apps.quotation_items hi on hi.quotation_item_id = h.quotation_item_id
           where btrim(hi.part_number) = btrim(qi.part_number)
             and nullif(btrim(hi.part_number), '') is not null
             and hi.quotation_id <> p_quotation_id
             and h.cost > 0)
        end as historical_best,
        coalesce((
          select jsonb_agg(jsonb_build_object(
                   'vendor_id', vi.vendor_id, 'cost', vi.cost,
                   'agency_price', vi.agency_price, 'discount_percent', vi.discount_percent,
                   'available_quantity', vi.available_quantity,
                   'vendor_part_number', vi.vendor_part_number,
                   'status', vi.vendor_item_status, 'is_best', vi.best_cost))
            from qvm_new_apps.quotation_vendor_items vi
           where vi.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as offers
      from qvm_new_apps.quotation_items qi
     where qi.quotation_id = p_quotation_id) r;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('order', v_order, 'vendors', v_vendors, 'items', v_rows));
end $function$;
-- qvm_new_apps.wa_complete_outbox(p_outbox_id bigint, p_ok boolean, p_wa_message_id text, p_error text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_complete_outbox(p_outbox_id bigint, p_ok boolean, p_wa_message_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_msg bigint; v_attempts integer; v_giveup boolean;
BEGIN
  SELECT message_id, attempts INTO v_msg, v_attempts
    FROM qvm_new_apps.wa_outbox WHERE outbox_id = p_outbox_id;
  IF v_msg IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'outbox row not found', 'data', NULL);
  END IF;

  IF p_ok THEN
    UPDATE qvm_new_apps.wa_outbox
       SET status = 'sent', last_error = NULL, updated_at = now()
     WHERE outbox_id = p_outbox_id;
    UPDATE qvm_new_apps.wa_messages
       SET delivery_status = 'sent',
           wa_message_id   = COALESCE(NULLIF(p_wa_message_id, ''), wa_message_id),
           failed_reason   = NULL
     WHERE message_id = v_msg;
  ELSE
    v_giveup := v_attempts >= 5;
    UPDATE qvm_new_apps.wa_outbox
       SET status          = CASE WHEN v_giveup THEN 'failed' ELSE 'queued' END,
           next_attempt_at = now() + (LEAST(v_attempts, 4) * interval '3 minutes'),
           last_error      = LEFT(COALESCE(p_error, 'send failed'), 500),
           updated_at      = now()
     WHERE outbox_id = p_outbox_id;
    UPDATE qvm_new_apps.wa_messages
       SET delivery_status = CASE WHEN v_giveup THEN 'failed' ELSE 'queued' END,
           failed_reason   = LEFT(COALESCE(p_error, 'send failed'), 500)
     WHERE message_id = v_msg;
  END IF;

  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_create_vendor_from_contact(p_wa_contact_id bigint, p_vendor_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_create_vendor_from_contact(p_wa_contact_id bigint, p_vendor_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_phone text; v_name text := NULLIF(btrim(p_vendor_name), ''); v_vendor integer;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  IF v_name IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'vendor name is required', 'data', NULL);
  END IF;

  SELECT phone_e164 INTO v_phone FROM qvm_new_apps.wa_contacts
   WHERE wa_contact_id = p_wa_contact_id AND chat_type = 'individual';
  IF v_phone IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'contact not found', 'data', NULL);
  END IF;

  INSERT INTO qvm_new_apps.vendors (vendor_name, phone_numbers)
  VALUES (v_name, jsonb_build_array(v_phone))
  RETURNING vendor_id INTO v_vendor;

  UPDATE qvm_new_apps.wa_contacts
     SET vendor_id = v_vendor, display_name = COALESCE(display_name, v_name),
         linked_by = auth.uid(), linked_at = now()
   WHERE wa_contact_id = p_wa_contact_id;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('vendor_id', v_vendor, 'vendor_name', v_name));
END;
$function$;
-- qvm_new_apps.wa_delete_message(p_message_id bigint, p_revoke boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_delete_message(p_message_id bigint, p_revoke boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m record; v_target text; v_queued boolean := false;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT message_id, thread_id, direction, wa_message_id, deleted_at
    INTO m FROM qvm_new_apps.wa_messages WHERE message_id = p_message_id;
  IF m IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'message not found', 'data', NULL);
  END IF;
  IF m.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', true, 'message', 'already deleted', 'data', NULL);
  END IF;

  UPDATE qvm_new_apps.wa_messages
     SET deleted_at = now(), deleted_by = auth.uid()
   WHERE message_id = p_message_id;

  -- Unsend on WhatsApp only makes sense for our own delivered messages.
  IF p_revoke AND m.direction = 'out' AND NULLIF(m.wa_message_id, '') IS NOT NULL THEN
    SELECT CASE WHEN c.chat_type = 'group'
                THEN COALESCE(c.wa_jid, c.phone_e164 || '@g.us')
                ELSE c.phone_e164 END
      INTO v_target
      FROM qvm_new_apps.wa_threads t
      JOIN qvm_new_apps.wa_contacts c ON c.wa_contact_id = t.wa_contact_id
     WHERE t.thread_id = m.thread_id;

    IF v_target IS NOT NULL THEN
      INSERT INTO qvm_new_apps.wa_outbox (
        message_id, thread_id, to_phone, kind, target_wa_message_id)
      VALUES (p_message_id, m.thread_id, v_target, 'revoke', m.wa_message_id)
      ON CONFLICT (message_id) DO NOTHING;
      v_queued := true;
    END IF;
  END IF;

  -- If the deleted message was the preview, fall back to the newest survivor.
  UPDATE qvm_new_apps.wa_threads t
     SET last_message_preview = COALESCE((
           SELECT LEFT(COALESCE(NULLIF(x.body, ''), '📎 مرفق'), 160)
             FROM qvm_new_apps.wa_messages x
            WHERE x.thread_id = t.thread_id AND x.deleted_at IS NULL
            ORDER BY x.wa_timestamp DESC, x.message_id DESC LIMIT 1), '')
   WHERE t.thread_id = m.thread_id;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('revoke_queued', v_queued));
END;
$function$;
-- qvm_new_apps.wa_delete_thread(p_thread_id bigint, p_purge_messages boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_delete_thread(p_thread_id bigint, p_purge_messages boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_msgs integer;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  UPDATE qvm_new_apps.wa_threads
     SET deleted_at = now(), deleted_by = auth.uid(), unread_count = 0
   WHERE thread_id = p_thread_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', false, 'message', 'thread not found', 'data', NULL);
  END IF;

  -- Optional harder clean: also hide every message, so that if the vendor
  -- writes again the thread comes back empty rather than carrying the old
  -- history back with it.
  IF p_purge_messages THEN
    UPDATE qvm_new_apps.wa_messages
       SET deleted_at = now(), deleted_by = auth.uid()
     WHERE thread_id = p_thread_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_msgs = ROW_COUNT;
  ELSE
    v_msgs := 0;
  END IF;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('messages_hidden', v_msgs));
END;
$function$;
-- qvm_new_apps.wa_device_signal()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_device_signal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  perform qvm_new_apps.wa_signal('wa:device', 'changed');
  return null;
end
$function$;
-- qvm_new_apps.wa_forward_message(p_message_id bigint, p_target_thread_id bigint, p_note text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_forward_message(p_message_id bigint, p_target_thread_id bigint, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE src record; v_target text; v_msg bigint; v_body text;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT m.body, m.media_url, m.media_mime, m.media_kind, m.media_name
    INTO src FROM qvm_new_apps.wa_messages m WHERE m.message_id = p_message_id;
  IF src IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'message not found', 'data', NULL);
  END IF;

  SELECT CASE WHEN c.chat_type = 'group'
              THEN COALESCE(c.wa_jid, c.phone_e164 || '@g.us')
              ELSE c.phone_e164 END
    INTO v_target
    FROM qvm_new_apps.wa_threads t
    JOIN qvm_new_apps.wa_contacts c ON c.wa_contact_id = t.wa_contact_id
   WHERE t.thread_id = p_target_thread_id;
  IF v_target IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'target thread not found', 'data', NULL);
  END IF;

  v_body := COALESCE(NULLIF(btrim(p_note), '') || E'\n\n', '') || COALESCE(src.body, '');
  IF NULLIF(btrim(v_body), '') IS NULL AND src.media_url IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'nothing to forward', 'data', NULL);
  END IF;

  INSERT INTO qvm_new_apps.wa_messages (
    thread_id, direction, body, media_url, media_mime, media_kind, media_name,
    sent_by, wa_timestamp, delivery_status)
  VALUES (p_target_thread_id, 'out', NULLIF(v_body, ''), src.media_url, src.media_mime,
          src.media_kind, src.media_name, auth.uid(), now(), 'queued')
  RETURNING message_id INTO v_msg;

  INSERT INTO qvm_new_apps.wa_outbox (
    message_id, thread_id, to_phone, body, media_url, media_mime, media_kind, media_name)
  VALUES (v_msg, p_target_thread_id, v_target, NULLIF(v_body, ''), src.media_url,
          src.media_mime, src.media_kind, src.media_name);

  UPDATE qvm_new_apps.wa_threads
     SET last_message_at = now(),
         last_message_preview = LEFT(COALESCE(NULLIF(v_body, ''), '📎 مرفق'), 160),
         status = CASE WHEN status = 'closed' THEN 'open' ELSE status END
   WHERE thread_id = p_target_thread_id;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('message_id', v_msg));
END;
$function$;
-- qvm_new_apps.wa_forward_targets(p_exclude_thread bigint, p_query text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_forward_targets(p_exclude_thread bigint, p_query text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_q text := nullif(btrim(coalesce(p_query,'')),'');
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.last_message_at desc nulls last), '[]'::jsonb)
    into v from (
      select t.thread_id, c.phone_e164, c.chat_type,
             coalesce(v.vendor_name, c.display_name, c.phone_e164) as title,
             t.last_message_at
        from qvm_new_apps.wa_threads t
        join qvm_new_apps.wa_contacts c on c.wa_contact_id = t.wa_contact_id
        left join qvm_new_apps.vendors v on v.vendor_id = c.vendor_id
       where t.thread_id <> coalesce(p_exclude_thread, -1)
         and (v_q is null
              or c.phone_e164 ilike '%'||v_q||'%'
              or c.display_name ilike '%'||v_q||'%'
              or v.vendor_name ilike '%'||v_q||'%')
       order by t.last_message_at desc nulls last
       limit 12) x;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end $function$;
-- qvm_new_apps.wa_get_device_state()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_get_device_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select to_jsonb(x) into v from (
    select d.device_id, d.state, d.jid, d.phone, d.connected_at, d.last_seen_at, d.last_error,
           d.pair_requested_at, d.qr_expires_at,
           case when d.state = 'pairing' and d.qr_expires_at > now() then d.qr_png end as qr_png,
           (d.last_seen_at is not null and d.last_seen_at > now() - interval '90 seconds') as bridge_online,
           (select count(*) from qvm_new_apps.wa_outbox where status in ('queued','sending')) as pending_outbox,
           (select count(*) from qvm_new_apps.wa_outbox where status = 'failed') as failed_outbox,
           (select count(*) from qvm_new_apps.wa_messages
             where wa_timestamp >= date_trunc('day', now()) and deleted_at is null) as messages_today,
           (select coalesce(sum(unread_count), 0) from qvm_new_apps.wa_threads
             where status <> 'closed' and deleted_at is null) as unread_badge
      from qvm_new_apps.wa_device_state d where d.id = 1) x;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end $function$;
-- qvm_new_apps.wa_get_thread(p_thread_id bigint, p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_get_thread(p_thread_id bigint, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_head jsonb; v_msgs jsonb;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select to_jsonb(x) into v_head from (
    select t.thread_id, t.status, t.unread_count, t.assigned_to, t.quotation_id,
           t.last_message_at, t.last_inbound_at,
           t.channel, t.subject,
           (t.typing_until is not null and t.typing_until > now()) as is_typing,
           c.wa_contact_id, c.phone_e164, c.display_name, c.vendor_id, c.vendor_branch_id,
           c.email,
           c.avatar_path, c.chat_type, v.vendor_name, ud.user_name as assigned_to_name,
           q.order_number, q.plate_number
      from qvm_new_apps.wa_threads t
      join qvm_new_apps.wa_contacts c on c.wa_contact_id = t.wa_contact_id
      left join qvm_new_apps.vendors    v  on v.vendor_id    = c.vendor_id
      left join qvm_new_apps.user_data  ud on ud.user_id     = t.assigned_to
      left join qvm_new_apps.quotations q  on q.quotation_id = t.quotation_id
     where t.thread_id = p_thread_id) x;
  if v_head is null then
    return jsonb_build_object('status', false, 'message', 'thread not found', 'data', null);
  end if;

  select coalesce(jsonb_agg(to_jsonb(m) order by m.wa_timestamp, m.message_id), '[]'::jsonb)
    into v_msgs from (
      select z.* from (
        select msg.message_id, msg.direction, msg.body, msg.media_url, msg.media_mime,
               msg.media_kind, msg.media_name, msg.is_internal_note, msg.is_system,
               msg.wa_timestamp, msg.delivery_status, msg.failed_reason, msg.sent_by,
               msg.sender_name, u.user_name as sent_by_name,
               msg.reply_to_message_id,
               -- The laid-out original, when the mail had one. The bubble renders
               -- this instead of the flattened text.
               msg.email_html_path,
               case when msg.reply_to_message_id is not null or msg.reply_to_wa_id is not null then (
                 select jsonb_build_object(
                          'message_id', r.message_id,
                          'direction', r.direction,
                          'body', case when r.deleted_at is not null then null else r.body end,
                          'media_kind', r.media_kind,
                          'deleted', r.deleted_at is not null,
                          'author', case when r.direction = 'out'
                                         then coalesce(ru.user_name, 'QVM')
                                         else coalesce(r.sender_name, '') end)
                   from qvm_new_apps.wa_messages r
                   left join qvm_new_apps.user_data ru on ru.user_id = r.sent_by
                  where r.message_id = msg.reply_to_message_id
                     or (msg.reply_to_wa_id is not null and r.wa_message_id = msg.reply_to_wa_id)
                  limit 1)
               end as reply_to
          from qvm_new_apps.wa_messages msg
          left join qvm_new_apps.user_data u on u.user_id = msg.sent_by
         where msg.thread_id = p_thread_id
           and msg.deleted_at is null          -- soft-deleted messages disappear
         order by msg.wa_timestamp desc, msg.message_id desc
         limit greatest(coalesce(p_limit,200),1)) z) m;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('thread', v_head, 'messages', v_msgs));
end $function$;
-- qvm_new_apps.wa_health_check()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_health_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d record; v_healthy boolean; v_reason text; v_now_state text; v_last text;
  v_title text; v_body text; v_notif bigint; v_author uuid; v_failed integer;
  v_recipients integer := 0;
begin
  select * into d from qvm_new_apps.wa_device_state where id = 1;
  select count(*) into v_failed from qvm_new_apps.wa_outbox where status = 'failed';

  if d is null then
    v_healthy := false; v_reason := 'حالة الجهاز غير موجودة في قاعدة البيانات';
  elsif d.last_seen_at is null or d.last_seen_at < now() - interval '5 minutes' then
    v_healthy := false; v_reason := 'خدمة الجسر على الخادم متوقفة';
  elsif d.state <> 'connected' then
    v_healthy := false; v_reason := 'رقم واتساب غير مربوط — يحتاج مسح رمز QR من جديد';
  else
    v_healthy := true;
  end if;

  v_now_state := case when v_healthy then 'ok' else 'down' end;
  select value into v_last from qvm_new_apps.wa_settings where key = 'health_last_state';

  if v_last is null then
    insert into qvm_new_apps.wa_settings (key, value) values ('health_last_state', v_now_state)
    on conflict (key) do update set value = excluded.value, updated_at = now();
    return jsonb_build_object('status', true, 'healthy', v_healthy, 'notified', false, 'seeded', true);
  end if;

  if v_last = v_now_state then
    return jsonb_build_object('status', true, 'healthy', v_healthy, 'notified', false);
  end if;

  update qvm_new_apps.wa_settings set value = v_now_state, updated_at = now()
   where key = 'health_last_state';

  if v_healthy then
    v_title := '✅ قناة واتساب رجعت';
    v_body  := 'الاتصال اشتغل تاني والرسايل بتوصل عادي.'
               || case when v_failed > 0
                    then ' في ' || v_failed || ' رسالة فشل إرسالها وقت الانقطاع — راجعها من الوارد.'
                    else '' end;
  else
    v_title := '⚠️ قناة واتساب واقفة';
    v_body  := v_reason || '. الرسايل الجديدة مش هتوصل والردود هتفضل في الطابور لحد ما ترجع.';
  end if;

  select user_id into v_author from qvm_new_apps.user_data
   where user_role = 172 order by user_id limit 1;
  if v_author is null then
    return jsonb_build_object('status', false, 'message', 'no admin to attribute the alert to');
  end if;

  for d in
    select user_id from qvm_new_apps.user_data where user_type = 185 or user_role = 172
  loop
    insert into qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
    values (v_title, v_body,
            jsonb_build_object('kind','wa_channel','healthy',v_healthy,'route','/inbox'),
            'user', d.user_id, v_author)
    returning id into v_notif;

    insert into qvm_new_apps.notification_reads (notification_id, user_id)
    values (v_notif, d.user_id);

    insert into qvm_new_apps.notification_deliveries (notification_id, device_token_id, status)
    select v_notif, dt.id, 'pending' from qvm_new_apps.device_tokens dt
     where dt.user_id = d.user_id and dt.is_active;

    -- Push is best effort: a failed push must never abort the alert itself.
    begin
      perform net.http_post(
        url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object('notification_id', v_notif));
    exception when others then null;
    end;

    v_recipients := v_recipients + 1;
  end loop;

  return jsonb_build_object('status', true, 'healthy', v_healthy,
                            'notified', true, 'recipients', v_recipients, 'reason', v_reason);
end $function$;
-- qvm_new_apps.wa_ingest_message(p_wa_message_id text, p_jid text, p_phone text, p_display_name text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text, p_media_name text, p_chat_type text, p_sender_jid text, p_sender_name text, p_reply_to_wa_id text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_ingest_message(p_wa_message_id text, p_jid text, p_phone text, p_display_name text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text DEFAULT NULL::text, p_media_name text DEFAULT NULL::text, p_chat_type text DEFAULT 'individual'::text, p_sender_jid text DEFAULT NULL::text, p_sender_name text DEFAULT NULL::text, p_reply_to_wa_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_contact bigint; v_thread bigint; v_msg bigint;
  v_at timestamptz := coalesce(p_wa_timestamp, now());
  v_digits text := regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g');
  v_nsn text := qvm_new_apps.wa_norm_phone(p_phone);
  v_group boolean := coalesce(p_chat_type,'individual') = 'group';
  v_preview text; v_reply_local bigint;
begin
  if v_digits = '' then
    return jsonb_build_object('status', false, 'message', 'chat id required', 'data', null);
  end if;

  insert into qvm_new_apps.wa_contacts (phone_e164, phone_nsn, wa_jid, display_name, chat_type)
  values (v_digits, case when v_group then null else v_nsn end,
          nullif(p_jid,''), nullif(p_display_name,''),
          case when v_group then 'group' else 'individual' end)
  on conflict (phone_e164) do update
    set wa_jid = coalesce(excluded.wa_jid, qvm_new_apps.wa_contacts.wa_jid),
        display_name = coalesce(qvm_new_apps.wa_contacts.display_name, excluded.display_name),
        phone_nsn = excluded.phone_nsn, chat_type = excluded.chat_type
  returning wa_contact_id into v_contact;

  if not v_group then
    update qvm_new_apps.wa_contacts c set vendor_id = v.vendor_id
      from (select vendor_id from qvm_new_apps.vendors,
                   lateral jsonb_array_elements_text(
                     case when jsonb_typeof(phone_numbers)='array' then phone_numbers else '[]'::jsonb end) as ph(num)
             where qvm_new_apps.wa_norm_phone(ph.num) = v_nsn limit 1) v
     where c.wa_contact_id = v_contact and c.vendor_id is null;
  end if;

  insert into qvm_new_apps.wa_threads (wa_contact_id, channel) values (v_contact, 'whatsapp')
  on conflict (wa_contact_id) where channel = 'whatsapp'
    do update set wa_contact_id = excluded.wa_contact_id
  returning thread_id into v_thread;

  -- A hidden conversation comes back when the vendor writes again.
  perform qvm_new_apps.wa_revive_thread(v_thread);

  if nullif(p_reply_to_wa_id,'') is not null then
    select message_id into v_reply_local
      from qvm_new_apps.wa_messages where wa_message_id = p_reply_to_wa_id limit 1;
  end if;

  insert into qvm_new_apps.wa_messages (
    thread_id, wa_message_id, direction, body, media_url, media_mime, media_kind, media_name,
    sender_jid, sender_name, wa_timestamp, delivery_status, raw,
    reply_to_wa_id, reply_to_message_id)
  values (v_thread, nullif(p_wa_message_id,''), 'in', p_body, nullif(p_media_url,''),
          nullif(p_media_mime,''), nullif(p_media_kind,''), nullif(p_media_name,''),
          coalesce(nullif(p_sender_jid,''), nullif(p_jid,'')), nullif(p_sender_name,''),
          v_at, 'received', p_raw, nullif(p_reply_to_wa_id,''), v_reply_local)
  on conflict (wa_message_id) where wa_message_id is not null do nothing
  returning message_id into v_msg;

  if v_msg is null then
    return jsonb_build_object('status', true, 'message', 'duplicate',
      'data', jsonb_build_object('duplicate', true, 'thread_id', v_thread, 'contact_id', v_contact));
  end if;

  v_preview := coalesce(nullif(p_body,''), case p_media_kind
    when 'image' then '📷 صورة' when 'video' then '🎥 فيديو'
    when 'voice' then '🎤 رسالة صوتية' when 'audio' then '🎵 مقطع صوتي'
    when 'sticker' then '🩹 ملصق' when 'document' then '📎 ملف'
    else case when p_media_url is not null then '📎 مرفق' else '' end end);
  if v_group and nullif(p_sender_name,'') is not null then
    v_preview := p_sender_name || ': ' || v_preview;
  end if;

  update qvm_new_apps.wa_threads
     set last_message_at = greatest(coalesce(last_message_at, to_timestamp(0)), v_at),
         last_inbound_at = greatest(coalesce(last_inbound_at, to_timestamp(0)), v_at),
         last_message_preview = left(v_preview, 160),
         unread_count = unread_count + 1,
         status = case when status = 'closed' then 'open' else status end
   where thread_id = v_thread;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('duplicate', false, 'thread_id', v_thread,
                               'contact_id', v_contact, 'message_id', v_msg));
end;
$function$;
-- qvm_new_apps.wa_ingest_outbound(p_wa_message_id text, p_jid text, p_phone text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text, p_media_name text, p_reply_to_wa_id text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_ingest_outbound(p_wa_message_id text, p_jid text, p_phone text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text DEFAULT NULL::text, p_media_name text DEFAULT NULL::text, p_reply_to_wa_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_contact bigint; v_thread bigint; v_msg bigint;
  v_at timestamptz := coalesce(p_wa_timestamp, now());
  v_digits text := regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g');
  v_nsn text := qvm_new_apps.wa_norm_phone(p_phone);
  v_preview text; v_reply_local bigint;
begin
  if v_nsn is null or nullif(p_wa_message_id,'') is null then
    return jsonb_build_object('status', false, 'message', 'phone and message id required', 'data', null);
  end if;
  if exists (select 1 from qvm_new_apps.wa_messages where wa_message_id = p_wa_message_id) then
    return jsonb_build_object('status', true, 'message', 'duplicate',
      'data', jsonb_build_object('duplicate', true));
  end if;

  insert into qvm_new_apps.wa_contacts (phone_e164, phone_nsn, wa_jid)
  values (v_digits, v_nsn, nullif(p_jid,''))
  on conflict (phone_e164) do update
    set wa_jid = coalesce(excluded.wa_jid, qvm_new_apps.wa_contacts.wa_jid)
  returning wa_contact_id into v_contact;

  insert into qvm_new_apps.wa_threads (wa_contact_id) values (v_contact)
  on conflict (wa_contact_id) do update set wa_contact_id = excluded.wa_contact_id
  returning thread_id into v_thread;

  update qvm_new_apps.wa_messages m
     set wa_message_id = p_wa_message_id,
         delivery_status = case when m.delivery_status = 'queued' then 'sent' else m.delivery_status end
   where m.message_id = (
     select message_id from qvm_new_apps.wa_messages
      where thread_id = v_thread and direction = 'out' and not is_internal_note
        and wa_message_id is null and created_at > now() - interval '10 minutes'
        and coalesce(body,'') = coalesce(p_body,'')
      order by message_id desc limit 1)
  returning m.message_id into v_msg;

  if v_msg is not null then
    return jsonb_build_object('status', true, 'message', 'adopted',
      'data', jsonb_build_object('adopted', true, 'thread_id', v_thread, 'message_id', v_msg));
  end if;

  if nullif(p_reply_to_wa_id,'') is not null then
    select message_id into v_reply_local
      from qvm_new_apps.wa_messages where wa_message_id = p_reply_to_wa_id limit 1;
  end if;

  insert into qvm_new_apps.wa_messages (
    thread_id, wa_message_id, direction, body, media_url, media_mime, media_kind, media_name,
    wa_timestamp, delivery_status, raw, reply_to_wa_id, reply_to_message_id)
  values (v_thread, p_wa_message_id, 'out', p_body, nullif(p_media_url,''),
          nullif(p_media_mime,''), nullif(p_media_kind,''), nullif(p_media_name,''),
          v_at, 'sent', p_raw, nullif(p_reply_to_wa_id,''), v_reply_local)
  on conflict (wa_message_id) where wa_message_id is not null do nothing
  returning message_id into v_msg;

  if v_msg is null then
    return jsonb_build_object('status', true, 'message', 'duplicate',
      'data', jsonb_build_object('duplicate', true, 'thread_id', v_thread));
  end if;

  v_preview := coalesce(nullif(p_body,''), case p_media_kind
    when 'image' then '📷 صورة' when 'video' then '🎥 فيديو'
    when 'voice' then '🎤 رسالة صوتية' when 'audio' then '🎵 مقطع صوتي'
    when 'sticker' then '🩹 ملصق' when 'document' then '📎 ملف'
    else case when p_media_url is not null then '📎 مرفق' else '' end end);

  update qvm_new_apps.wa_threads
     set last_message_at = greatest(coalesce(last_message_at, to_timestamp(0)), v_at),
         last_message_preview = left(v_preview, 160),
         status = case when status = 'closed' then 'open' else status end
   where thread_id = v_thread;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('duplicate', false, 'thread_id', v_thread, 'message_id', v_msg));
end $function$;
-- qvm_new_apps.wa_is_internal()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_is_internal()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
     WHERE u.user_id = auth.uid()
       AND (u.user_type = 185 OR u.user_role = 172)
  );
$function$;
-- qvm_new_apps.wa_link_contact(p_wa_contact_id bigint, p_vendor_id integer, p_vendor_branch_id bigint, p_display_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_link_contact(p_wa_contact_id bigint, p_vendor_id integer, p_vendor_branch_id bigint DEFAULT NULL::bigint, p_display_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  UPDATE qvm_new_apps.wa_contacts
     SET vendor_id        = p_vendor_id,
         vendor_branch_id = p_vendor_branch_id,
         display_name     = COALESCE(NULLIF(p_display_name, ''), display_name),
         linked_by        = auth.uid(),
         linked_at        = now()
   WHERE wa_contact_id = p_wa_contact_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', false, 'message', 'contact not found', 'data', NULL);
  END IF;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_list_assignees()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_list_assignees()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.user_name), '[]'::jsonb) INTO v
    FROM (
      SELECT u.user_id, COALESCE(u.user_name, u.email) AS user_name, u.email,
             (SELECT count(*) FROM qvm_new_apps.wa_threads t
               WHERE t.assigned_to = u.user_id AND t.status <> 'closed') AS open_threads
        FROM qvm_new_apps.user_data u
       WHERE u.user_type = 185 OR u.user_role = 172
    ) x;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', v);
END;
$function$;
-- qvm_new_apps.wa_list_threads(p_status text, p_search text, p_only_mine boolean, p_limit integer, p_offset integer, p_channel text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_list_threads(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_only_mine boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_channel text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb; v_total bigint; v_q text := nullif(btrim(coalesce(p_search,'')),'');
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  with base as (
    select t.thread_id, t.status, t.unread_count, t.last_message_at, t.last_message_preview,
           t.assigned_to, t.quotation_id, t.channel, t.subject,
           (t.typing_until is not null and t.typing_until > now()) as is_typing,
           c.wa_contact_id, c.phone_e164, c.display_name, c.vendor_id, c.avatar_path, c.chat_type,
           c.email,
           v.vendor_name, ud.user_name as assigned_to_name, q.order_number
      from qvm_new_apps.wa_threads t
      join qvm_new_apps.wa_contacts c on c.wa_contact_id = t.wa_contact_id
      left join qvm_new_apps.vendors    v  on v.vendor_id    = c.vendor_id
      left join qvm_new_apps.user_data  ud on ud.user_id     = t.assigned_to
      left join qvm_new_apps.quotations q  on q.quotation_id = t.quotation_id
     where t.deleted_at is null
       and (p_status is null or t.status = p_status)
       and (p_channel is null or t.channel = p_channel)
       and (not p_only_mine or t.assigned_to = auth.uid())
       and (v_q is null
            or c.phone_e164 ilike '%'||v_q||'%'
            or c.email ilike '%'||v_q||'%'
            or c.display_name ilike '%'||v_q||'%'
            or t.subject ilike '%'||v_q||'%'
            or v.vendor_name ilike '%'||v_q||'%'
            or t.last_message_preview ilike '%'||v_q||'%'
            or q.order_number ilike '%'||v_q||'%'
            or exists (select 1 from qvm_new_apps.wa_messages m
                        where m.thread_id = t.thread_id and m.deleted_at is null
                          and m.body ilike '%'||v_q||'%')
            or exists (select 1 from qvm_new_apps.quotation_items qi
                        where qi.quotation_id = t.quotation_id
                          and (qi.part_number ilike '%'||v_q||'%'
                               or qi.part_description ilike '%'||v_q||'%')))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.last_message_at desc nulls last), '[]'::jsonb),
         (select count(*) from base)
    into v_rows, v_total
    from (select * from base order by last_message_at desc nulls last
           limit greatest(coalesce(p_limit,50),1) offset greatest(coalesce(p_offset,0),0)) x;
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('threads', v_rows, 'total', v_total,
      'counters', (select jsonb_build_object(
          'open', count(*) filter (where status='open'),
          'pending', count(*) filter (where status='pending'),
          'closed', count(*) filter (where status='closed'),
          'mine', count(*) filter (where assigned_to = auth.uid() and status <> 'closed'),
          'unassigned', count(*) filter (where assigned_to is null and status <> 'closed'),
          'unread', coalesce(sum(unread_count) filter (where status<>'closed'),0))
        from qvm_new_apps.wa_threads where deleted_at is null)));
end $function$;
-- qvm_new_apps.wa_mark_read(p_thread_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_mark_read(p_thread_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  UPDATE qvm_new_apps.wa_threads SET unread_count = 0 WHERE thread_id = p_thread_id;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_messages_signal()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_messages_signal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_thread bigint := coalesce(new.thread_id, old.thread_id);
begin
  -- The open conversation redraws, and every panel's thread list reorders.
  perform qvm_new_apps.wa_signal('wa:thread:' || v_thread, 'changed');
  perform qvm_new_apps.wa_signal('wa:threads', 'changed');
  return null;
end
$function$;
-- qvm_new_apps.wa_norm_phone(p_phone text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_norm_phone(p_phone text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT NULLIF(RIGHT(regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g'), 9), '');
$function$;
-- qvm_new_apps.wa_note_quote_superseded()
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
-- qvm_new_apps.wa_notify_colleague(p_thread_id bigint, p_user_id uuid, p_note text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_notify_colleague(p_thread_id bigint, p_user_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_note text := NULLIF(btrim(p_note), '');
  v_msg bigint; v_notif bigint; v_who text; v_from text;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  IF v_note IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'note is required', 'data', NULL);
  END IF;

  SELECT COALESCE(v.vendor_name, c.display_name, c.phone_e164) INTO v_who
    FROM qvm_new_apps.wa_threads t
    JOIN qvm_new_apps.wa_contacts c ON c.wa_contact_id = t.wa_contact_id
    LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = c.vendor_id
   WHERE t.thread_id = p_thread_id;
  IF v_who IS NULL THEN
    RETURN jsonb_build_object('status', false, 'message', 'thread not found', 'data', NULL);
  END IF;

  SELECT COALESCE(user_name, email) INTO v_from
    FROM qvm_new_apps.user_data WHERE user_id = auth.uid();

  INSERT INTO qvm_new_apps.wa_messages (
    thread_id, direction, body, sent_by, is_internal_note, wa_timestamp, delivery_status)
  VALUES (p_thread_id, 'out', v_note, auth.uid(), true, now(), 'note')
  RETURNING message_id INTO v_msg;

  INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
  VALUES ('💬 ' || COALESCE(v_from, 'زميل') || ' نبّهك في محادثة ' || v_who,
          v_note,
          jsonb_build_object('kind', 'wa_mention', 'thread_id', p_thread_id, 'route', '/inbox'),
          'user', p_user_id, auth.uid())
  RETURNING id INTO v_notif;

  INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
  VALUES (v_notif, p_user_id);

  INSERT INTO qvm_new_apps.notification_deliveries (notification_id, device_token_id, status)
  SELECT v_notif, dt.id, 'pending' FROM qvm_new_apps.device_tokens dt
   WHERE dt.user_id = p_user_id AND dt.is_active;

  BEGIN
    PERFORM net.http_post(
      url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/send-push-notification',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('notification_id', v_notif));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('message_id', v_msg, 'notification_id', v_notif));
END;
$function$;
-- qvm_new_apps.wa_outbox_notify()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_outbox_notify()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- Only queued rows are claimable. A row parked on next_attempt_at (a retry
  -- after a failed send) still needs the safety poll to pick it up later, so
  -- the bridge must not treat NOTIFY as its only wake-up.
  if new.status = 'queued'
     and (new.next_attempt_at is null or new.next_attempt_at <= now()) then
    perform pg_notify('wa_outbox', '');
  end if;
  return null;
end
$function$;
-- qvm_new_apps.wa_request_pairing(p_disconnect boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_request_pairing(p_disconnect boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  UPDATE qvm_new_apps.wa_device_state
     SET pair_requested_at = CASE WHEN p_disconnect THEN NULL ELSE now() END,
         state             = CASE WHEN p_disconnect THEN 'disconnecting' ELSE state END,
         qr_png            = NULL,
         qr_expires_at     = NULL,
         last_error        = NULL,
         updated_at        = now()
   WHERE id = 1;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_revive_thread(p_thread_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_revive_thread(p_thread_id bigint)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update qvm_new_apps.wa_threads
     set deleted_at = null, deleted_by = null
   where thread_id = p_thread_id and deleted_at is not null;
$function$;
-- qvm_new_apps.wa_search_orders(p_query text, p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_search_orders(p_query text, p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb; v_q text := NULLIF(btrim(COALESCE(p_query, '')), '');
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::jsonb) INTO v
    FROM (
      SELECT q.quotation_id, q.order_number, q.plate_number, q.created_at
        FROM qvm_new_apps.quotations q
       WHERE v_q IS NULL
          OR q.order_number ILIKE '%' || v_q || '%'
          OR q.plate_number ILIKE '%' || v_q || '%'
       ORDER BY q.created_at DESC
       LIMIT GREATEST(COALESCE(p_limit, 12), 1)
    ) x;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', v);
END;
$function$;
-- qvm_new_apps.wa_search_vendors(p_query text, p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_search_vendors(p_query text, p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb; v_q text := NULLIF(btrim(COALESCE(p_query, '')), '');
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.vendor_name), '[]'::jsonb) INTO v
    FROM (
      SELECT vd.vendor_id, vd.vendor_name,
             COALESCE(vd.phone_numbers, '[]'::jsonb) AS phone_numbers
        FROM qvm_new_apps.vendors vd
       WHERE v_q IS NULL
          OR vd.vendor_name ILIKE '%' || v_q || '%'
          OR vd.zoho_name   ILIKE '%' || v_q || '%'
          OR regexp_replace(COALESCE(vd.phone_numbers::text, ''), '[^0-9]', '', 'g')
             LIKE '%' || regexp_replace(v_q, '[^0-9]', '', 'g') || '%'
             AND regexp_replace(v_q, '[^0-9]', '', 'g') <> ''
       ORDER BY vd.vendor_name
       LIMIT GREATEST(COALESCE(p_limit, 12), 1)
    ) x;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', v);
END;
$function$;
-- qvm_new_apps.wa_send_message(p_thread_id bigint, p_body text, p_media_url text, p_media_mime text, p_is_internal_note boolean, p_media_kind text, p_media_name text, p_reply_to_message_id bigint)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_send_message(p_thread_id bigint, p_body text, p_media_url text DEFAULT NULL::text, p_media_mime text DEFAULT NULL::text, p_is_internal_note boolean DEFAULT false, p_media_kind text DEFAULT NULL::text, p_media_name text DEFAULT NULL::text, p_reply_to_message_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_target text; v_msg bigint; v_note boolean := coalesce(p_is_internal_note, false);
  v_kind text := nullif(p_media_kind, ''); v_preview text; v_reply_wa text;
  v_channel text; v_to_email text; v_account bigint; v_subject text;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null and p_media_url is null then
    return jsonb_build_object('status', false, 'message', 'empty message', 'data', null);
  end if;

  if p_media_url is not null and v_kind is null then
    v_kind := case
      when p_media_mime like 'image/%' then 'image'
      when p_media_mime like 'video/%' then 'video'
      when p_media_mime like 'audio/%' then 'audio'
      else 'document' end;
  end if;
  if v_kind is not null and v_kind not in ('image','video','audio','voice','sticker','document') then
    return jsonb_build_object('status', false, 'message', 'invalid media kind', 'data', null);
  end if;

  select t.channel,
         case when c.chat_type = 'group'
              then coalesce(c.wa_jid, c.phone_e164 || '@g.us')
              else c.phone_e164 end,
         c.email, t.email_account_id, t.subject
    into v_channel, v_target, v_to_email, v_account, v_subject
    from qvm_new_apps.wa_threads t
    join qvm_new_apps.wa_contacts c on c.wa_contact_id = t.wa_contact_id
   where t.thread_id = p_thread_id;

  if v_channel is null then
    return jsonb_build_object('status', false, 'message', 'thread not found', 'data', null);
  end if;
  if v_channel = 'whatsapp' and v_target is null then
    return jsonb_build_object('status', false, 'message', 'thread not found', 'data', null);
  end if;
  if v_channel = 'email' and (v_to_email is null or v_account is null) then
    return jsonb_build_object('status', false, 'message', 'this mailbox is no longer linked', 'data', null);
  end if;
  -- A voice note is a WhatsApp idea; over email it is just an audio file, and
  -- calling it a voice note would render it with a waveform the vendor's mail
  -- client cannot play inline.
  if v_channel = 'email' and v_kind = 'voice' then
    v_kind := 'audio';
  end if;

  if p_reply_to_message_id is not null then
    select wa_message_id into v_reply_wa
      from qvm_new_apps.wa_messages
     where message_id = p_reply_to_message_id and thread_id = p_thread_id;
  end if;

  if v_channel = 'email' and v_reply_wa is null then
    select wa_message_id into v_reply_wa
      from qvm_new_apps.wa_messages
     where thread_id = p_thread_id and direction = 'in' and wa_message_id is not null
     order by wa_timestamp desc limit 1;
  end if;

  insert into qvm_new_apps.wa_messages (
    thread_id, direction, body, media_url, media_mime, media_kind, media_name,
    sent_by, is_internal_note, wa_timestamp, delivery_status,
    reply_to_message_id, reply_to_wa_id)
  values (p_thread_id, 'out', p_body, p_media_url, p_media_mime, v_kind, nullif(p_media_name,''),
          auth.uid(), v_note, now(), case when v_note then 'note' else 'queued' end,
          p_reply_to_message_id, v_reply_wa)
  returning message_id into v_msg;

  if not v_note then
    if v_channel = 'email' then
      insert into qvm_new_apps.wa_outbox (
        message_id, thread_id, channel, to_email, email_account_id, subject, body,
        media_url, media_mime, media_kind, media_name, reply_to_wa_id)
      values (v_msg, p_thread_id, 'email', v_to_email, v_account,
              case when coalesce(v_subject,'') = '' then 'Re:'
                   when v_subject ~* '^\s*re\s*:' then v_subject
                   else 'Re: ' || v_subject end,
              p_body, p_media_url, p_media_mime, v_kind, nullif(p_media_name,''), v_reply_wa);
    else
      insert into qvm_new_apps.wa_outbox (
        message_id, thread_id, to_phone, body, media_url, media_mime, media_kind, media_name,
        reply_to_wa_id)
      values (v_msg, p_thread_id, v_target, p_body, p_media_url, p_media_mime, v_kind,
              nullif(p_media_name,''), v_reply_wa);
    end if;
  end if;

  v_preview := coalesce(nullif(p_body,''), case v_kind
    when 'image' then '📷 صورة' when 'video' then '🎥 فيديو'
    when 'voice' then '🎤 رسالة صوتية' when 'audio' then '🎵 مقطع صوتي'
    when 'sticker' then '🩹 ملصق' when 'document' then '📎 ملف' else '📎 مرفق' end);

  update qvm_new_apps.wa_threads
     set last_message_at = now(),
         last_message_preview = left(case when v_note then '🔒 ' else '' end || v_preview, 160),
         status = case when status = 'closed' then 'open' else status end
   where thread_id = p_thread_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('message_id', v_msg, 'queued', not v_note));
end
$function$;
-- qvm_new_apps.wa_set_avatar(p_wa_contact_id bigint, p_avatar_path text, p_avatar_id text, p_push_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_set_avatar(p_wa_contact_id bigint, p_avatar_path text DEFAULT NULL::text, p_avatar_id text DEFAULT NULL::text, p_push_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  UPDATE qvm_new_apps.wa_contacts
     SET avatar_path  = COALESCE(NULLIF(p_avatar_path, ''), avatar_path),
         avatar_id    = COALESCE(NULLIF(p_avatar_id, ''), avatar_id),
         wa_push_name = COALESCE(NULLIF(p_push_name, ''), wa_push_name),
         -- A contact with no name of its own gets the WhatsApp profile name.
         display_name = COALESCE(display_name, NULLIF(p_push_name, '')),
         avatar_checked_at = now()
   WHERE wa_contact_id = p_wa_contact_id;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_set_device_state(p_device_id text, p_state text, p_jid text, p_qr_png text, p_qr_ttl_seconds integer, p_error text, p_clear_pair_request boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_set_device_state(p_device_id text DEFAULT NULL::text, p_state text DEFAULT NULL::text, p_jid text DEFAULT NULL::text, p_qr_png text DEFAULT NULL::text, p_qr_ttl_seconds integer DEFAULT NULL::integer, p_error text DEFAULT NULL::text, p_clear_pair_request boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v jsonb;
  -- Read before the UPDATE: inside the SET list, `state` would already be the
  -- new value, so the transition could not be detected there.
  v_unlinking boolean;
BEGIN
  SELECT (state = 'disconnecting' AND p_state = 'disconnected')
    INTO v_unlinking
    FROM qvm_new_apps.wa_device_state WHERE id = 1;

  UPDATE qvm_new_apps.wa_device_state
     SET device_id     = COALESCE(p_device_id, device_id),
         state         = COALESCE(p_state, state),
         jid           = CASE WHEN v_unlinking THEN NULL
                              ELSE COALESCE(NULLIF(p_jid, ''), jid) END,
         phone         = CASE WHEN v_unlinking THEN NULL
                              ELSE COALESCE(split_part(NULLIF(p_jid, ''), '@', 1), phone) END,
         qr_png        = CASE WHEN p_qr_png IS NOT NULL THEN p_qr_png
                              WHEN p_state = 'connected' THEN NULL ELSE qr_png END,
         qr_expires_at = CASE WHEN p_qr_png IS NOT NULL THEN now() + make_interval(secs => COALESCE(p_qr_ttl_seconds, 30))
                              WHEN p_state = 'connected' THEN NULL ELSE qr_expires_at END,
         connected_at  = CASE WHEN p_state = 'connected' AND state <> 'connected' THEN now()
                              WHEN p_state = 'connected' THEN connected_at ELSE NULL END,
         pair_requested_at = CASE WHEN p_clear_pair_request OR p_state = 'connected' THEN NULL
                                  ELSE pair_requested_at END,
         last_error    = CASE WHEN p_error IS NOT NULL THEN LEFT(p_error, 500) ELSE last_error END,
         last_seen_at  = now(),
         updated_at    = now()
   WHERE id = 1;

  SELECT to_jsonb(x) INTO v FROM (
    SELECT device_id, state, pair_requested_at FROM qvm_new_apps.wa_device_state WHERE id = 1) x;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', v);
END;
$function$;
-- qvm_new_apps.wa_set_typing(p_phone text, p_seconds integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_set_typing(p_phone text, p_seconds integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_digits text := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');
BEGIN
  UPDATE qvm_new_apps.wa_threads t
     SET typing_until = now() + make_interval(secs => GREATEST(COALESCE(p_seconds, 12), 1))
    FROM qvm_new_apps.wa_contacts c
   WHERE c.wa_contact_id = t.wa_contact_id AND c.phone_e164 = v_digits;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- qvm_new_apps.wa_signal(p_topic text, p_event text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_signal(p_topic text, p_event text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  perform realtime.send(jsonb_build_object('at', now()), p_event, p_topic, true);
exception when others then
  null;
end
$function$;
-- qvm_new_apps.wa_start_thread(p_phone text, p_vendor_id integer, p_display_name text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_start_thread(p_phone text, p_vendor_id integer DEFAULT NULL::integer, p_display_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_digits  text := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');
  v_nsn     text;
  v_contact bigint;
  v_thread  bigint;
  v_existed boolean;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  IF v_digits !~ '^[0-9]{8,15}$' THEN
    RETURN jsonb_build_object('status', false, 'message', 'invalid phone number', 'data', NULL);
  END IF;

  v_nsn := qvm_new_apps.wa_norm_phone(v_digits);

  SELECT t.thread_id INTO v_thread
    FROM qvm_new_apps.wa_contacts c
    JOIN qvm_new_apps.wa_threads t ON t.wa_contact_id = c.wa_contact_id
   WHERE c.phone_e164 = v_digits;
  v_existed := v_thread IS NOT NULL;

  INSERT INTO qvm_new_apps.wa_contacts (phone_e164, phone_nsn, wa_jid, display_name, chat_type)
  VALUES (v_digits, v_nsn, v_digits || '@s.whatsapp.net', NULLIF(p_display_name, ''), 'individual')
  ON CONFLICT (phone_e164) DO UPDATE
    SET display_name = COALESCE(qvm_new_apps.wa_contacts.display_name, EXCLUDED.display_name)
  RETURNING wa_contact_id INTO v_contact;

  -- An explicit vendor wins over whatever auto-matching guessed.
  IF p_vendor_id IS NOT NULL THEN
    UPDATE qvm_new_apps.wa_contacts
       SET vendor_id = p_vendor_id, linked_by = auth.uid(), linked_at = now()
     WHERE wa_contact_id = v_contact;
  ELSE
    UPDATE qvm_new_apps.wa_contacts c
       SET vendor_id = v.vendor_id
      FROM (
        SELECT vendor_id
          FROM qvm_new_apps.vendors, LATERAL jsonb_array_elements_text(
                 CASE WHEN jsonb_typeof(phone_numbers) = 'array' THEN phone_numbers ELSE '[]'::jsonb END
               ) AS ph(num)
         WHERE qvm_new_apps.wa_norm_phone(ph.num) = v_nsn
         LIMIT 1
      ) v
     WHERE c.wa_contact_id = v_contact AND c.vendor_id IS NULL;
  END IF;

  INSERT INTO qvm_new_apps.wa_threads (wa_contact_id, assigned_to)
  VALUES (v_contact, auth.uid())
  ON CONFLICT (wa_contact_id) DO UPDATE SET wa_contact_id = EXCLUDED.wa_contact_id
  RETURNING thread_id INTO v_thread;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('thread_id', v_thread, 'existed', COALESCE(v_existed, false)));
END;
$function$;
-- qvm_new_apps.wa_thread_orders(p_thread_id bigint, p_limit integer)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_thread_orders(p_thread_id bigint, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_vendor integer; v_pinned integer; v jsonb;
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;

  SELECT c.vendor_id, t.quotation_id INTO v_vendor, v_pinned
    FROM qvm_new_apps.wa_threads t
    JOIN qvm_new_apps.wa_contacts c ON c.wa_contact_id = t.wa_contact_id
   WHERE t.thread_id = p_thread_id;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.is_pinned DESC, x.created_at DESC), '[]'::jsonb)
    INTO v
    FROM (
      SELECT
        q.quotation_id,
        q.order_number,
        q.plate_number,
        q.created_at,
        (q.quotation_id = v_pinned)                    AS is_pinned,
        -- What this vendor was asked for, and how far it got.
        (SELECT count(*) FROM qvm_new_apps.quotation_vendor_items vi
          WHERE vi.quotation_vendor_id = qv.quotation_vendor_id)                      AS items,
        (SELECT count(*) FROM qvm_new_apps.quotation_vendor_items vi
          WHERE vi.quotation_vendor_id = qv.quotation_vendor_id AND vi.cost > 0)      AS priced,
        (SELECT count(*) FROM qvm_new_apps.quotation_items qi
          WHERE qi.quotation_id = q.quotation_id AND qi.item_status = 19)             AS confirmed,
        (SELECT count(*) FROM qvm_new_apps.quotation_items qi
          WHERE qi.quotation_id = q.quotation_id
            AND qi.item_status IN (21, 22))                                           AS processing,
        -- Still live for this vendor: nothing priced yet, or the order itself
        -- has confirmed/processing lines moving through it.
        ((SELECT count(*) FROM qvm_new_apps.quotation_vendor_items vi
           WHERE vi.quotation_vendor_id = qv.quotation_vendor_id
             AND vi.vendor_item_status = 157) > 0
         OR (SELECT count(*) FROM qvm_new_apps.quotation_items qi
              WHERE qi.quotation_id = q.quotation_id
                AND qi.item_status IN (19, 21, 22, 235, 236, 237)) > 0)               AS is_active
      FROM qvm_new_apps.quotation_vendors qv
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qv.quotation_id
     WHERE (v_vendor IS NOT NULL AND qv.vendor_id = v_vendor)
        OR q.quotation_id = v_pinned
     GROUP BY q.quotation_id, q.order_number, q.plate_number, q.created_at, qv.quotation_vendor_id
     ORDER BY q.created_at DESC
     LIMIT GREATEST(COALESCE(p_limit, 40), 1)
    ) x;

  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('vendor_id', v_vendor, 'pinned', v_pinned, 'orders', v));
END;
$function$;
-- qvm_new_apps.wa_threads_signal()
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_threads_signal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  perform qvm_new_apps.wa_signal('wa:threads', 'changed');
  if tg_op = 'UPDATE' then
    perform qvm_new_apps.wa_signal('wa:thread:' || new.thread_id, 'changed');
  end if;
  return null;
end
$function$;
-- qvm_new_apps.wa_update_delivery(p_wa_message_id text, p_status text)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_update_delivery(p_wa_message_id text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NULLIF(p_wa_message_id, '') IS NULL OR p_status NOT IN ('sent','delivered','read','failed') THEN
    RETURN jsonb_build_object('status', false, 'message', 'invalid input', 'data', NULL);
  END IF;
  UPDATE qvm_new_apps.wa_messages
     SET delivery_status = p_status
   WHERE wa_message_id = p_wa_message_id
     AND direction = 'out'
     AND COALESCE(array_position(ARRAY['queued','sent','delivered','read'], delivery_status), 0)
         < array_position(ARRAY['queued','sent','delivered','read'], p_status);
  RETURN jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('updated', FOUND));
END;
$function$;
-- qvm_new_apps.wa_update_thread(p_thread_id bigint, p_status text, p_assigned_to uuid, p_clear_assignee boolean, p_quotation_id integer, p_clear_quotation boolean)
CREATE OR REPLACE FUNCTION qvm_new_apps.wa_update_thread(p_thread_id bigint, p_status text DEFAULT NULL::text, p_assigned_to uuid DEFAULT NULL::uuid, p_clear_assignee boolean DEFAULT false, p_quotation_id integer DEFAULT NULL::integer, p_clear_quotation boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT qvm_new_apps.wa_is_internal() THEN
    RETURN jsonb_build_object('status', false, 'message', 'forbidden', 'data', NULL);
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('open', 'pending', 'closed') THEN
    RETURN jsonb_build_object('status', false, 'message', 'invalid status', 'data', NULL);
  END IF;

  UPDATE qvm_new_apps.wa_threads
     SET status       = COALESCE(p_status, status),
         assigned_to  = CASE WHEN p_clear_assignee THEN NULL
                             ELSE COALESCE(p_assigned_to, assigned_to) END,
         quotation_id = CASE WHEN p_clear_quotation THEN NULL
                             ELSE COALESCE(p_quotation_id, quotation_id) END
   WHERE thread_id = p_thread_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', false, 'message', 'thread not found', 'data', NULL);
  END IF;
  RETURN jsonb_build_object('status', true, 'message', 'ok', 'data', NULL);
END;
$function$;
-- public.add_note(p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text, p_note_attachment text)
CREATE OR REPLACE FUNCTION public.add_note(p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text, p_note_attachment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN qvm_new_apps.add_note(
        p_note_type,
        p_type_id,
        p_is_internal,
        p_note_description,
        p_note_attachment
    );
END;
$function$;
-- public.get_vendor_quotation_extras_by_token(p_token uuid)
CREATE OR REPLACE FUNCTION public.get_vendor_quotation_extras_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  select qvm_new_apps.get_vendor_quotation_extras_by_token(p_token);
$function$;