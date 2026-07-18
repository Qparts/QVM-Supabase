-- Snapshot of core RPC functions from QVM (public and qvm_new_apps)
-- Generated: 2026-02-04

BEGIN;

-- public.count_active_rfq_orders
CREATE OR REPLACE FUNCTION public.count_active_rfq_orders(p_account_manager uuid)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT qvm_new_apps.count_active_rfq_orders(p_account_manager);
$function$;

-- public.create_quotation
CREATE OR REPLACE FUNCTION public.create_quotation(p_order_number text, p_plate_number text, p_order_type integer, p_delivery_type integer, p_service_advisor uuid, p_account_manager uuid)
 RETURNS qvm_new_apps.quotations
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_quotation qvm_new_apps.quotations;
BEGIN
  INSERT INTO qvm_new_apps.quotations (
    order_number,
    plate_number,
    order_type,
    delivery_type,
    service_advisor,
    account_manager,
    shipping_type
  ) VALUES (
    p_order_number,
    p_plate_number,
    p_order_type,
    p_delivery_type,
    p_service_advisor,
    p_account_manager,
    'item'
  )
  RETURNING * INTO v_quotation;
  
  RETURN v_quotation;
END;
$function$;

-- public.create_quotation_items
CREATE OR REPLACE FUNCTION public.create_quotation_items(p_items jsonb)
 RETURNS SETOF qvm_new_apps.quotation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$BEGIN
  RETURN QUERY
  INSERT INTO qvm_new_apps.quotation_items (
    quotation_id,
    customer_id,
    vin,
    main_brand,
    model,
    part_number,
    part_description,
    quantity,
    brand_class,
    part_photo,
    item_status,
    estimated_price
  )
  SELECT
    (item->>'quotation_id')::integer,
    (item->>'customer_id')::bigint,
    nullif(item->>'vin', 'null')::text,
    (item->'main_brand')::integer,
    nullif(item->>'model', 'null')::text,
    nullif(item->>'part_number', 'null')::text,
    nullif(item->>'part_description', 'null')::text,
    (item->>'quantity')::integer,
    (item->'brand_class')::integer,
    nullif(item->>'part_photo', 'null')::text,
    (item->>'item_status')::integer,
    nullif(item->>'estimated_price', 'null')::numeric
  FROM jsonb_array_elements(p_items) AS item
  RETURNING *;
END;$function$;

-- public.create_quotation_note
CREATE OR REPLACE FUNCTION public.create_quotation_note(p_type_id integer, p_note text, p_user_id uuid)
 RETURNS qvm_new_apps.notes
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_note qvm_new_apps.notes;
BEGIN
  INSERT INTO qvm_new_apps.notes (
    type_id,
    note_type,
    note,
    user_id
  ) VALUES (
    p_type_id,
    'quotations',
    p_note,
    p_user_id
  )
  RETURNING * INTO v_note;
  
  RETURN v_note;
END;
$function$;

-- public.generate_rfq_order_number
CREATE OR REPLACE FUNCTION public.generate_rfq_order_number(p_client_id integer, p_region_id integer)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT qvm_new_apps.generate_rfq_order_number(
    p_client_id,
    p_region_id
  );
$function$;

-- public.get_account_manager_allocation
CREATE OR REPLACE FUNCTION public.get_account_manager_allocation(customer_id_param bigint, slot_param integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result json;
BEGIN
  SELECT row_to_json(t) INTO result
  FROM qvm_new_apps.account_manager_allocations t
  WHERE t.customer_id = customer_id_param 
  AND t.slot_number = slot_param;
  
  RETURN result;
END;
$function$;

-- public.get_account_manager_branch
CREATE OR REPLACE FUNCTION public.get_account_manager_branch(p_customer_id bigint, p_slot_number integer)
 RETURNS TABLE(id uuid, customer_id bigint, slot_number smallint, main_account_manager uuid, first_substitute uuid, second_substitute uuid, fallback_account_manager uuid, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    amb.id,
    amb.customer_id,
    amb.slot_number,
    amb.main_account_manager,
    amb.first_substitute,
    amb.second_substitute,
    amb.fallback_account_manager,
    amb.created_at,
    amb.updated_at
  FROM 
    qvm_new_apps.account_manager_branches amb
  WHERE 
    amb.customer_id = p_customer_id
    AND amb.slot_number = p_slot_number;
END;
$function$;

-- public.get_available_manager_slot
CREATE OR REPLACE FUNCTION public.get_available_manager_slot(p_manager_id uuid, p_slot_number integer, p_day text)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT ams.id
  FROM qvm_new_apps.account_manager_slots ams
  WHERE ams.account_manager = p_manager_id
    AND ams.slot_number = p_slot_number
    AND ams.is_available = true
    AND (
      (p_day = 'saturday' AND ams.saturday = true) OR
      (p_day = 'sunday' AND ams.sunday = true) OR
      (p_day = 'monday' AND ams.monday = true) OR
      (p_day = 'tuesday' AND ams.tuesday = true) OR
      (p_day = 'wednesday' AND ams.wednesday = true) OR
      (p_day = 'thursday' AND ams.thursday = true)
    )
  LIMIT 1;
END;
$function$;

-- public.get_brand_classes
CREATE OR REPLACE FUNCTION public.get_brand_classes()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;
    return qvm_new_apps.get_brand_classes();
end;
$function$;

-- public.get_car_brands
CREATE OR REPLACE FUNCTION public.get_car_brands()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;
    return qvm_new_apps.get_car_brands();
end;
$function$;

-- public.get_client_branch
CREATE OR REPLACE FUNCTION public.get_client_branch(p_customer_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;
    return qvm_new_apps.get_client_branch(p_customer_id);
end;
$function$;

-- public.get_clients
CREATE OR REPLACE FUNCTION public.get_clients()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;
    return qvm_new_apps.get_clients();
end;
$function$;

-- public.get_estimated_price
CREATE OR REPLACE FUNCTION public.get_estimated_price(p_client_id integer, p_part_number text)
 RETURNS numeric
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT qvm_new_apps.get_estimated_price(
    p_client_id,
    p_part_number
  );
$function$;

-- public.get_list_data_json
CREATE OR REPLACE FUNCTION public.get_list_data_json(p_list_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result_data jsonb;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'list_data_id', ld.list_data_id,
            'list_data_name', ld.list_data
        )
        ORDER BY ld.list_data
    )
    INTO result_data
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE l.list_name = p_list_name;

    RETURN jsonb_build_object(
        'status', true,
        'message', p_list_name || ' list retrieved',
        'data', COALESCE(result_data, '[]'::jsonb)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'status', false,
            'message', 'Error retrieving ' || p_list_name || ': ' || SQLERRM,
            'data', '[]'::jsonb
        );
END;
$function$;

-- qvm_new_apps.count_active_rfq_orders
CREATE OR REPLACE FUNCTION qvm_new_apps.count_active_rfq_orders(p_account_manager uuid)
 RETURNS integer
 LANGUAGE sql
AS $function$
  select count(distinct q.quotation_id)
  from qvm_new_apps.quotations q
  left join qvm_new_apps.quotation_items qi
    on qi.quotation_id = q.quotation_id
  left join qvm_new_apps.confirmed_items ci
    on ci.quotation_item_id = qi.quotation_item_id
  where q.account_manager = p_account_manager
  and (
    qi.item_status in (15,21,17,19,16,23,28,29)
    or ci.item_status in (15,21,17,19,16,23,28,29)
  );
$function$;

-- qvm_new_apps.generate_rfq_order_number
CREATE OR REPLACE FUNCTION qvm_new_apps.generate_rfq_order_number(p_client_id integer, p_region_id integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_prefix TEXT;
  v_next   INT;
BEGIN
  SELECT ons.prefix
  INTO v_prefix
  FROM qvm_new_apps.order_number_sequences ons
  WHERE ons.lists_data_id = p_client_id
    AND ons.region_id = p_region_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Order sequence not configured for client % and region %',
      p_client_id, p_region_id;
  END IF;

  PERFORM 1
  FROM qvm_new_apps.quotations q
  WHERE q.order_number LIKE v_prefix || '%'
  FOR UPDATE;

  SELECT COALESCE(
           MAX(
             substring(q.order_number FROM '(\d+)$')::INT
           ),
           0
         ) + 1
  INTO v_next
  FROM qvm_new_apps.quotations q
  WHERE q.order_number LIKE v_prefix || '%'
    AND q.order_number ~ '\d+$';

  RETURN v_prefix || v_next;
END;
$function$;

-- qvm_new_apps.get_brand_classes
CREATE OR REPLACE FUNCTION qvm_new_apps.get_brand_classes()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;

    select json_build_object(
        'status', true,
        'message', 'brand classes retrieved',
        'data', coalesce(
            json_agg(
                json_build_object(
                    'brand_class_id', ld.list_data_id,
                    'brand_class_name', ld.list_data
                )
            ),
            '[]'::json
        )
    )
    into result
    from qvm_new_apps.list_data ld
    join qvm_new_apps.lists l
        on l.list_id = ld.list_id
    where l.list_name = 'brand_class';

    return result;
END;
$function$;

-- qvm_new_apps.get_car_brands
CREATE OR REPLACE FUNCTION qvm_new_apps.get_car_brands()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;

    select json_build_object(
        'status', true,
        'message', 'car brands retrieved',
        'data', coalesce(
            json_agg(
                json_build_object(
                    'main_brand_id', ld.list_data_id,
                    'main_brand_name', ld.list_data
                )
            ),
            '[]'::json
        )
    )
    into result
    from qvm_new_apps.list_data ld
    join qvm_new_apps.lists l
        on l.list_id = ld.list_id
    where l.list_name = 'car_brand';

    return result;
END;
$function$;

-- qvm_new_apps.get_client_branch
CREATE OR REPLACE FUNCTION qvm_new_apps.get_client_branch(p_customer_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;

    select json_build_object(
        'status', true,
        'message', 'branch data retrieved',
        'data', coalesce(
            json_agg(row_to_json(b)),
            '[]'::json
        )
    )
    into result
    from qvm_new_apps.client_branches b
    where b.list_data_id = p_customer_id;

    return result;
END;
$function$;

-- qvm_new_apps.get_clients
CREATE OR REPLACE FUNCTION qvm_new_apps.get_clients()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;

    select json_build_object(
        'status', true,
        'message', 'client list retrieved',
        'data', coalesce(
            json_agg(
                json_build_object(
                    'client_id', ld.list_data_id,
                    'client_name', ld.list_data
                )
            ),
            '[]'::json
        )
    )
    into result
    from qvm_new_apps.list_data ld
    join qvm_new_apps.lists l
        on l.list_id = ld.list_id
    where l.list_name = 'client_name';

    return result;
END;
$function$;

-- qvm_new_apps.get_estimated_price
CREATE OR REPLACE FUNCTION qvm_new_apps.get_estimated_price(p_client_id integer, p_part_number text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_price NUMERIC;
    v_price_found BOOLEAN := FALSE;
    v_last_price NUMERIC;
    v_price_age INT;
    v_margin NUMERIC := 0;
BEGIN
    -- 1️⃣ Check if the same client purchased the same part with same brand class in the last 60 days
    SELECT qi.price_before_vat
    INTO v_last_price
    FROM qvm_new_apps.quotation_items qi
    JOIN qvm_new_apps.quotations q
        ON qi.quotation_id = q.quotation_id
    WHERE qi.part_number = p_part_number
      AND qi.brand_class = p_brand_class_id
      AND qi.customer_id IN (
        SELECT customer_id
        FROM qvm_new_apps.client_branches
        WHERE list_data_id = p_client_id
      )
      AND q.created_at >= NOW() - INTERVAL '60 days'
      AND qi.price_before_vat IS NOT NULL
    ORDER BY q.created_at DESC
    LIMIT 1;

    IF FOUND THEN
        v_price := v_last_price;
        v_price_found := TRUE;
    END IF;

    -- 2️⃣ If no price found, search quotation_vendor_items table with brand class
    IF NOT v_price_found THEN
        -- Get last historical price with same brand class
        SELECT qvi.cost
        INTO v_last_price
        FROM qvm_new_apps.quotation_vendor_items qvi
        join qvm_new_apps.quotation_items qii
            on (qvi.quotation_item_id = qii.quotation_item_id)
        WHERE qii.part_number = p_part_number
          AND qii.brand_class = p_brand_class_id
        ORDER BY qvi.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            v_price := v_last_price;
            v_price_found := TRUE;

            -- Calculate age in days
            SELECT EXTRACT(DAY FROM NOW() - qvi.created_at)::INT
            INTO v_price_age
            FROM qvm_new_apps.quotation_vendor_items qvi
            join qvm_new_apps.quotation_items qii
                on (qvi.quotation_item_id = qii.quotation_item_id)
            WHERE qii.part_number = p_part_number
              AND qii.brand_class = p_brand_class_id
            ORDER BY qvi.created_at DESC
            LIMIT 1;

            -- 3️⃣ Determine cheap vs expensive
            IF v_price < 1000 THEN
                -- Cheap: search city/region/nationwide fallback
                -- For simplicity, apply +1%, +3%, +7% margin based on age
                IF v_price_age BETWEEN 90 AND 180 THEN
                    v_margin := 0.01;
                ELSIF v_price_age BETWEEN 181 AND 360 THEN
                    v_margin := 0.03;
                ELSIF v_price_age > 360 THEN
                    v_margin := 0.07;
                END IF;
            ELSE
                -- Expensive: nationwide search
                IF v_price_age BETWEEN 90 AND 180 THEN
                    v_margin := 0.01;
                ELSIF v_price_age BETWEEN 181 AND 360 THEN
                    v_margin := 0.03;
                ELSIF v_price_age > 360 THEN
                    v_margin := 0.07;
                END IF;
            END IF;

            -- Apply margin
            v_price := v_price * (1 + v_margin);
        END IF;
    END IF;

    -- 4️⃣ If still not found, return NULL to flag manual review
    IF NOT v_price_found THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_price, 2);

END;
$function$;

-- qvm_new_apps.get_list_data_json
CREATE OR REPLACE FUNCTION qvm_new_apps.get_list_data_json(p_list_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result_data jsonb;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'list_data_id', ld.list_data_id,
            'list_data_name', ld.list_data
        )
        ORDER BY ld.list_data
    )
    INTO result_data
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    WHERE l.list_name = p_list_name;

    RETURN jsonb_build_object(
        'status', true,
        'message', p_list_name || ' list retrieved',
        'data', COALESCE(result_data, '[]'::jsonb)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'status', false,
            'message', 'Error retrieving ' || p_list_name || ': ' || SQLERRM,
            'data', '[]'::jsonb
        );
END;
$function$;

COMMIT;
