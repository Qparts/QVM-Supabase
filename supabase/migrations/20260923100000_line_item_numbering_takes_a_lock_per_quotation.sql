-- Line item numbering takes a lock per quotation, and the duplicated unique index goes.
--
-- line_item_code is the legacy ORDER_NUMBER-N label. Nothing reads it any more (no frontend
-- reference, not part of the AppSheet row, no view or trigger), but the three writers still
-- compute it as MAX(existing)+1 with no lock, so parallel adds on one quotation collided:
--   duplicate key value violates unique constraint "quotation_items_line_item_code_uk"
-- Each writer now takes a transaction-scoped advisory lock keyed on the quotation before it
-- numbers the line. The column also carried two identical unique indexes; the standalone
-- _uk index is dropped and the _key constraint stays. reissue_cancelled_quantity derives its
-- code from the cancellation id (…-R<id>), so it needs no lock.
--
-- Function bodies are the live ones on QVM/dev with only the lock added (the test branch
-- carries the same change built from its own bodies).

DROP INDEX IF EXISTS qvm_new_apps.quotation_items_line_item_code_uk;

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
  -- Gate: internal-dashboard / create. A company that has taken this away from a role gets a
  -- refusal here, not merely a hidden button.
  PERFORM qvm_new_apps.require_page_permission('internal-dashboard', 'create');
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

  -- Serialise the ORDER-N numbering per quotation: two parallel inserts used to read the same
  -- MAX and collide on the unique line_item_code (23505). The lock is released at commit.
  PERFORM pg_advisory_xact_lock(hashtext('quotation_items.line_item_code'), p_quotation_id);
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

CREATE OR REPLACE FUNCTION public.add_quotation_item_by_vendor(p_quotation_id integer, p_part_number text DEFAULT NULL::text, p_part_description text DEFAULT NULL::text, p_quantity integer DEFAULT 1, p_brand_class integer DEFAULT NULL::integer, p_cost numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_agency_price numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid(); v_vendor bigint; v_utype text; v_qv_id bigint;
  v_status_added int; v_order_number text; v_next_index int; v_line_item_code text; v_item_id bigint;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('status','error','message','Not authenticated'); END IF;
  SELECT ud.user_vendor, ud.user_type::text INTO v_vendor, v_utype FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_user;
  IF v_vendor IS NULL OR v_utype <> '205' THEN RETURN jsonb_build_object('status','error','message','Only vendor users can add items'); END IF;
  SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = p_quotation_id;
  IF v_order_number IS NULL THEN RETURN jsonb_build_object('status','error','message','Invalid quotation_id'); END IF;
  -- The type (brand class) is what the pricing team and the workshop judge the suggestion by; a
  -- suggestion without one is not reviewable.
  IF p_brand_class IS NULL OR NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld WHERE ld.list_data_id = p_brand_class) THEN
    RETURN jsonb_build_object('status','error','message','Pick the item type');
  END IF;

  SELECT quotation_vendor_id INTO v_qv_id FROM qvm_new_apps.quotation_vendors
  WHERE quotation_id = p_quotation_id AND vendor_id = v_vendor LIMIT 1;
  IF v_qv_id IS NULL THEN
    INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, quotation_id, created_at)
    VALUES (v_vendor, p_quotation_id, now()) RETURNING quotation_vendor_id INTO v_qv_id;
  END IF;

  SELECT list_data_id INTO v_status_added FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Added by Vendor' LIMIT 1;

  -- Serialise the ORDER-N numbering per quotation: two parallel inserts used to read the same
  -- MAX and collide on the unique line_item_code (23505). The lock is released at commit.
  PERFORM pg_advisory_xact_lock(hashtext('quotation_items.line_item_code'), p_quotation_id);
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

  -- The two prices the vendor's own grid works in: cost is the price after discount (سعر الجملة),
  -- agency_price the price before it (سعر العميل), and the discount is derived, never typed.
  INSERT INTO qvm_new_apps.quotation_vendor_items (
    quotation_item_id, vendor_id, quotation_vendor_id, best_cost, cost, agency_price, discount_percent,
    from_database, vendor_item_status, created_at, updated_at
  ) VALUES (
    v_item_id, v_vendor, v_qv_id, false, p_cost, p_agency_price,
    CASE WHEN COALESCE(p_agency_price, 0) > 0 AND p_cost IS NOT NULL
         THEN round(((p_agency_price - p_cost) / p_agency_price) * 100, 2) END,
    false, NULL, now(), now());

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(p_note_type := 'quotation_items', p_type_id := v_item_id,
        p_note_description := p_note, p_note_id := NULL, p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status','success','quotation_item_id', v_item_id, 'line_item_code', v_line_item_code);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_quotation_items(p_items jsonb)
 RETURNS SETOF qvm_new_apps.quotation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Same per-quotation lock as the single-item writers, taken in a fixed order so two bulk
  -- creations touching the same quotations cannot deadlock.
  PERFORM pg_advisory_xact_lock(hashtext('quotation_items.line_item_code'), s.q)
  FROM (SELECT DISTINCT (item->>'quotation_id')::integer AS q
        FROM jsonb_array_elements(p_items) AS item ORDER BY 1) s;
  RETURN QUERY
  WITH input AS (
    SELECT
      (item->>'quotation_id')::integer AS quotation_id,
      (item->>'customer_id')::bigint AS customer_id,
      nullif(item->>'vin','null')::text AS vin,
      (item->>'main_brand')::integer AS main_brand,
      nullif(item->>'model','null')::text AS model,
      nullif(item->>'part_number','null')::text AS part_number,
      nullif(item->>'part_description','null')::text AS part_description,
      (item->>'quantity')::integer AS quantity,
      (item->>'brand_class')::integer AS brand_class,
      nullif(item->>'part_photo','null')::text AS part_photo,
      (item->>'item_status')::integer AS item_status,
      nullif(item->>'estimated_price','null')::numeric AS estimated_price,
      nullif(item->>'item_PK','null')::text AS item_pk
    FROM jsonb_array_elements(p_items) AS item
  ),
  existing_max AS (
    SELECT
      qi.quotation_id,
      COALESCE(MAX(NULLIF(substring(qi.line_item_code FROM '([0-9]+)$'), '')::int), 0) AS max_index
    FROM qvm_new_apps.quotation_items qi
    GROUP BY qi.quotation_id
  ),
  numbered AS (
    SELECT
      i.*,
      q.order_number,
      COALESCE(em.max_index, 0) AS base_index,
      ROW_NUMBER() OVER (PARTITION BY i.quotation_id ORDER BY i.quotation_id) AS rn
    FROM input i
    JOIN qvm_new_apps.quotations q ON q.quotation_id = i.quotation_id
    LEFT JOIN existing_max em ON em.quotation_id = i.quotation_id
  )
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
    estimated_price,
    item_pk,
    line_item_code
  )
  SELECT
    n.quotation_id,
    n.customer_id,
    n.vin,
    n.main_brand,
    n.model,
    n.part_number,
    n.part_description,
    n.quantity,
    n.brand_class,
    n.part_photo,
    n.item_status,
    n.estimated_price,
    n.item_pk,
    n.order_number || '-' || (n.base_index + n.rn)::text
  FROM numbered n
  RETURNING *;
END;
$function$;
