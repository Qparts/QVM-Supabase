-- The permission is enforced where the write happens.
--
-- A hidden button is a courtesy, not a control: an RPC is a URL and anyone signed in can post to
-- it. These are write paths on pages a company can be given, each asking the same question the
-- sidebar asked before it drew itself.
--
-- Reads are deliberately not gated here. Which rows a user may see is already decided by
-- effective_branch_ids, which narrows every dashboard to their own branches; view permission
-- governs whether the page is offered and reachable at all, and a second refusal over rows they
-- cannot see anyway would buy nothing.
--
-- This is the first pass, not the whole surface — see the commit message for what is still to be
-- wired. Everything not listed enforces exactly what it did before, which is the role check each
-- function already carries: nothing is less protected than it was yesterday.

-- add_rfq_item_inline: internal-dashboard / create
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

-- update_quotation_item_inline: internal-dashboard / update
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
  -- Gate: internal-dashboard / update. A company that has taken this away from a role gets a
  -- refusal here, not merely a hidden button.
  PERFORM qvm_new_apps.require_page_permission('internal-dashboard', 'update');
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

-- change_item_status_bulk: internal-dashboard / update
CREATE OR REPLACE FUNCTION public.change_item_status_bulk(p_quotation_item_ids integer[], p_new_status_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_uid uuid;
  v_user_type int;
  v_new_status_label text;
  v_blocked_ids int[];
  v_any_blocked int;
  v_updated_q int;
  v_updated_c int;
begin
  -- Gate: internal-dashboard / update. A company that has taken this away from a role gets a
  -- refusal here, not merely a hidden button.
  PERFORM qvm_new_apps.require_page_permission('internal-dashboard', 'update');
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  select user_type into v_user_type
  from qvm_new_apps.user_data
  where user_id = v_uid;

  if v_user_type <> 185 then
    raise exception 'Access denied: Internal users only';
  end if;

  select ld.list_data
  into v_new_status_label
  from qvm_new_apps.list_data ld
  where ld.list_data_id = p_new_status_id;

  if v_new_status_label is null then
    raise exception 'Invalid new status id %', p_new_status_id;
  end if;

  select array_agg(ld.list_data_id)
  into v_blocked_ids
  from qvm_new_apps.list_data ld
  join qvm_new_apps.lists l on l.list_id = ld.list_id
  where lower(l.list_name) in ('item_status', 'rfq_status', 'status')
    and lower(ld.list_data) in (
      'delivered','dn sign pending','rn sign pending',
      'pending invoice','pending credit note',
      'invoice issued','credit note issued','claim sent','settled'
    );

  select count(*)
  into v_any_blocked
  from (
    select qi.item_status as st
    from qvm_new_apps.quotation_items qi
    where qi.quotation_item_id = any(p_quotation_item_ids)
    union all
    select ci.item_status as st
    from qvm_new_apps.confirmed_items ci
    where ci.quotation_item_id = any(p_quotation_item_ids)
  ) s
  where s.st = any(v_blocked_ids);

  if coalesce(v_any_blocked, 0) > 0 then
    raise exception 'Selected items cannot be updated because their current status does not allow changes.';
  end if;

  with q_to_update as (
    select qi.quotation_item_id
    from qvm_new_apps.quotation_items qi
    left join qvm_new_apps.confirmed_items ci on ci.quotation_item_id = qi.quotation_item_id
    where qi.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is null
  )
  update qvm_new_apps.quotation_items qi
  set item_status = p_new_status_id
  from q_to_update u
  where qi.quotation_item_id = u.quotation_item_id;
  get diagnostics v_updated_q = row_count;

  insert into qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by)
  select u.quotation_item_id, p_new_status_id, v_uid
  from (
    select qi.quotation_item_id
    from qvm_new_apps.quotation_items qi
    left join qvm_new_apps.confirmed_items ci on ci.quotation_item_id = qi.quotation_item_id
    where qi.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is null
  ) u;

  with c_to_update as (
    select ci.confirmed_item_id
    from qvm_new_apps.confirmed_items ci
    where ci.quotation_item_id = any(p_quotation_item_ids)
  )
  update qvm_new_apps.confirmed_items ci
  set item_status = p_new_status_id
  from c_to_update u
  where ci.confirmed_item_id = u.confirmed_item_id;
  get diagnostics v_updated_c = row_count;

  insert into qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by)
  select ci.confirmed_item_id, p_new_status_id, v_uid
  from qvm_new_apps.confirmed_items ci
  where ci.quotation_item_id = any(p_quotation_item_ids);

  if lower(trim(v_new_status_label)) = 'delivered' then
    with target_confirmed as (
      select
        ci.confirmed_item_id,
        ci.confirmed_order_id,
        greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) as delivery_qty
      from qvm_new_apps.confirmed_items ci
      join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id from target_confirmed tc
    ),
    inserted_deliveries as (
      insert into qvm_new_apps.deliveries (confirmed_order_id)
      select to2.confirmed_order_id from target_orders to2
      where not exists (
        select 1 from qvm_new_apps.deliveries d where d.confirmed_order_id = to2.confirmed_order_id
      )
      returning delivery_id, confirmed_order_id
    ),
    resolved_deliveries as (
      select
        to2.confirmed_order_id,
        coalesce(id.delivery_id, existing_delivery.delivery_id) as delivery_id
      from target_orders to2
      left join inserted_deliveries id on id.confirmed_order_id = to2.confirmed_order_id
      left join lateral (
        select d_existing.delivery_id
        from qvm_new_apps.deliveries d_existing
        where d_existing.confirmed_order_id = to2.confirmed_order_id
        order by d_existing.created_at asc nulls last, d_existing.delivery_id asc
        limit 1
      ) existing_delivery on true
    )
    insert into qvm_new_apps.delivery_items (delivery_id, confirmed_item_id, delivered_qty, received_qty)
    select rd.delivery_id, tc.confirmed_item_id, tc.delivery_qty, tc.delivery_qty
    from target_confirmed tc
    join resolved_deliveries rd on rd.confirmed_order_id = tc.confirmed_order_id
    where rd.delivery_id is not null
      and not exists (
        select 1
        from qvm_new_apps.delivery_items di
        join qvm_new_apps.deliveries d2 on d2.delivery_id = di.delivery_id
        where d2.confirmed_order_id = tc.confirmed_order_id
          and di.confirmed_item_id = tc.confirmed_item_id
      );

    insert into qvm_new_apps.delivery_notes (
      order_number, client_name, branch, confirmation_date, delivery_date,
      final_part_number, part_description, main_brand, model, brand_class,
      vin, plate_number, approved_quantity,
      price_before_vat, total_price_before_vat,
      vat, total_price_including_vat,
      confirmed_item_id, discount_percent, shipping_price,
      created_at, updated_at
    )
    select
      q.order_number,
      coalesce(ld_client.list_data, ''),
      coalesce(cb.branch_name, ''),
      co.created_at,
      now()::date,
      coalesce(ci.final_part_number, qi.part_number, qi.alternative_part_number, ''),
      coalesce(qi.part_description, ''),
      coalesce(ld_brand.list_data, ''),
      coalesce(qi.model, ''),
      coalesce(ld_bc.list_data, ''),
      coalesce(qi.vin, ''),
      coalesce(q.plate_number, ''),
      greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1),
      coalesce(qi.price_before_vat, 0),
      round((coalesce(qi.price_before_vat, 0) * greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0))::numeric, 2),
      round((coalesce(qi.price_before_vat, 0) * greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 0.15)::numeric, 2),
      round((coalesce(qi.price_before_vat, 0) * greatest(coalesce(ci.approved_qty, qi.quantity, 1), 1) * (1 - coalesce(qi.discount_percent, 0) / 100.0) * 1.15)::numeric, 2),
      ci.confirmed_item_id,
      coalesce(qi.discount_percent, 0),
      coalesce(q.shipping_price, 0),
      now(),
      now()
    from qvm_new_apps.confirmed_items ci
    join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = ci.confirmed_order_id
    join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
    left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    left join qvm_new_apps.list_data ld_client on ld_client.list_data_id = cb.list_data_id
    left join qvm_new_apps.list_data ld_brand on ld_brand.list_data_id = qi.main_brand
    left join qvm_new_apps.list_data ld_bc on ld_bc.list_data_id = qi.brand_class
    where ci.quotation_item_id = any(p_quotation_item_ids)
      and ci.confirmed_item_id is not null
    on conflict (confirmed_item_id) do update set
      delivery_date = now()::date,
      price_before_vat = excluded.price_before_vat,
      total_price_before_vat = excluded.total_price_before_vat,
      vat = excluded.vat,
      total_price_including_vat = excluded.total_price_including_vat,
      discount_percent = excluded.discount_percent,
      shipping_price = excluded.shipping_price,
      updated_at = now();

  elsif lower(trim(v_new_status_label)) = 'return' then
    with target_confirmed as (
      select
        ci.confirmed_item_id,
        ci.confirmed_order_id,
        greatest(coalesce(ci.requested_return_qty, ci.approved_qty, qi.quantity, 1), 1) as item_return_qty
      from qvm_new_apps.confirmed_items ci
      join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
      where ci.quotation_item_id = any(p_quotation_item_ids)
        and ci.confirmed_item_id is not null
        and ci.confirmed_order_id is not null
    ),
    target_orders as (
      select distinct tc.confirmed_order_id from target_confirmed tc
    ),
    inserted_returns as (
      insert into qvm_new_apps.returns (confirmed_order_id)
      select to2.confirmed_order_id from target_orders to2
      where not exists (
        select 1 from qvm_new_apps.returns r where r.confirmed_order_id = to2.confirmed_order_id
      )
      returning return_id, confirmed_order_id
    ),
    resolved_returns as (
      select
        to2.confirmed_order_id,
        coalesce(ir.return_id, existing_return.return_id) as return_id
      from target_orders to2
      left join inserted_returns ir on ir.confirmed_order_id = to2.confirmed_order_id
      left join lateral (
        select r_existing.return_id
        from qvm_new_apps.returns r_existing
        where r_existing.confirmed_order_id = to2.confirmed_order_id
        order by r_existing.created_at asc nulls last, r_existing.return_id asc
        limit 1
      ) existing_return on true
    )
    insert into qvm_new_apps.return_items (return_id, confirmed_item_id, return_qty)
    select rr.return_id, tc.confirmed_item_id, tc.item_return_qty
    from target_confirmed tc
    join resolved_returns rr on rr.confirmed_order_id = tc.confirmed_order_id
    where rr.return_id is not null
      and not exists (
        select 1
        from qvm_new_apps.return_items ri
        join qvm_new_apps.returns r2 on r2.return_id = ri.return_id
        where r2.confirmed_order_id = tc.confirmed_order_id
          and ri.confirmed_item_id = tc.confirmed_item_id
      );
  end if;

  return jsonb_build_object(
    'status', 'success',
    'message', 'Statuses updated successfully',
    'updated_count', coalesce(v_updated_q, 0) + coalesce(v_updated_c, 0)
  );
end;
$function$;

-- upsert_account_manager_branch_inline: account-managers / update
CREATE OR REPLACE FUNCTION public.upsert_account_manager_branch_inline(
  p_user_id uuid,
  p_branch_id integer,
  p_changes jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean;
  v_changed text[] := ARRAY[]::text[];
  v_ex_main_s1 uuid; v_ex_main_s2 uuid; v_ex_main_s3 uuid;
  v_ex_sub1_s1 uuid; v_ex_sub1_s2 uuid; v_ex_sub1_s3 uuid;
  v_ex_sub2_s1 uuid; v_ex_sub2_s2 uuid; v_ex_sub2_s3 uuid;
  v_ex_fallback uuid;
  v_new_main_s1 uuid; v_new_main_s2 uuid; v_new_main_s3 uuid;
  v_new_sub1_s1 uuid; v_new_sub1_s2 uuid; v_new_sub1_s3 uuid;
  v_new_sub2_s1 uuid; v_new_sub2_s2 uuid; v_new_sub2_s3 uuid;
  v_new_fallback uuid;
  v_found_id int;
BEGIN
  -- Gate: account-managers / update. A company that has taken this away from a role gets a
  -- refusal here, not merely a hidden button.
  PERFORM qvm_new_apps.require_page_permission('account-managers', 'update');
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','pricing supervisor')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- ...and that this particular branch is one of theirs.
  PERFORM qvm_new_apps.assert_am_branch_in_scope(p_user_id, p_branch_id);

  SELECT
    CAST(MAX(CASE WHEN slot_number = 1 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (main_account_manager)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (first_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 1 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 2 THEN (second_substitute)::text END) AS uuid),
    CAST(MAX(CASE WHEN slot_number = 3 THEN (second_substitute)::text END) AS uuid),
    CAST(COALESCE(
      MAX(CASE WHEN slot_number = 1 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 2 THEN (fallback_account_manager)::text END),
      MAX(CASE WHEN slot_number = 3 THEN (fallback_account_manager)::text END)
    ) AS uuid)
  INTO
    v_ex_main_s1, v_ex_main_s2, v_ex_main_s3,
    v_ex_sub1_s1, v_ex_sub1_s2, v_ex_sub1_s3,
    v_ex_sub2_s1, v_ex_sub2_s2, v_ex_sub2_s3,
    v_ex_fallback
  FROM qvm_new_apps.account_manager_branches
  WHERE customer_id = p_branch_id::bigint;

  v_new_main_s1 := NULLIF(p_changes->>'main_s1','')::uuid;
  v_new_main_s2 := NULLIF(p_changes->>'main_s2','')::uuid;
  v_new_main_s3 := NULLIF(p_changes->>'main_s3','')::uuid;
  v_new_sub1_s1 := NULLIF(p_changes->>'sub1_s1','')::uuid;
  v_new_sub1_s2 := NULLIF(p_changes->>'sub1_s2','')::uuid;
  v_new_sub1_s3 := NULLIF(p_changes->>'sub1_s3','')::uuid;
  v_new_sub2_s1 := NULLIF(p_changes->>'sub2_s1','')::uuid;
  v_new_sub2_s2 := NULLIF(p_changes->>'sub2_s2','')::uuid;
  v_new_sub2_s3 := NULLIF(p_changes->>'sub2_s3','')::uuid;
  v_new_fallback := NULLIF(p_changes->>'fallback_user','')::uuid;

  IF p_changes ? 'main_s1' THEN
    IF v_new_main_s1 IS DISTINCT FROM v_ex_main_s1 THEN v_changed := array_append(v_changed, 'main_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_main_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s2' THEN
    IF v_new_main_s2 IS DISTINCT FROM v_ex_main_s2 THEN v_changed := array_append(v_changed, 'main_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_main_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'main_s3' THEN
    IF v_new_main_s3 IS DISTINCT FROM v_ex_main_s3 THEN v_changed := array_append(v_changed, 'main_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, main_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_main_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET main_account_manager = v_new_main_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s1' THEN
    IF v_new_sub1_s1 IS DISTINCT FROM v_ex_sub1_s1 THEN v_changed := array_append(v_changed, 'sub1_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub1_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s2' THEN
    IF v_new_sub1_s2 IS DISTINCT FROM v_ex_sub1_s2 THEN v_changed := array_append(v_changed, 'sub1_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub1_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub1_s3' THEN
    IF v_new_sub1_s3 IS DISTINCT FROM v_ex_sub1_s3 THEN v_changed := array_append(v_changed, 'sub1_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, first_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub1_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET first_substitute = v_new_sub1_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s1' THEN
    IF v_new_sub2_s1 IS DISTINCT FROM v_ex_sub2_s1 THEN v_changed := array_append(v_changed, 'sub2_s1'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 1 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_sub2_s1, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s1, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s2' THEN
    IF v_new_sub2_s2 IS DISTINCT FROM v_ex_sub2_s2 THEN v_changed := array_append(v_changed, 'sub2_s2'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 2 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 2, v_new_sub2_s2, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s2, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'sub2_s3' THEN
    IF v_new_sub2_s3 IS DISTINCT FROM v_ex_sub2_s3 THEN v_changed := array_append(v_changed, 'sub2_s3'); END IF;
    SELECT id INTO v_found_id FROM qvm_new_apps.account_manager_branches WHERE customer_id = p_branch_id::bigint AND slot_number = 3 LIMIT 1;
    IF v_found_id IS NULL THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, second_substitute, created_at, updated_at)
      VALUES (p_branch_id, 3, v_new_sub2_s3, now(), now());
    ELSE
      UPDATE qvm_new_apps.account_manager_branches
      SET second_substitute = v_new_sub2_s3, updated_at = now()
      WHERE id = v_found_id;
    END IF;
  END IF;

  IF p_changes ? 'fallback_user' THEN
    IF v_new_fallback IS DISTINCT FROM v_ex_fallback THEN v_changed := array_append(v_changed, 'fallback_user'); END IF;
    UPDATE qvm_new_apps.account_manager_branches
    SET fallback_account_manager = v_new_fallback, updated_at = now()
    WHERE customer_id = p_branch_id::bigint;
    IF NOT FOUND THEN
      INSERT INTO qvm_new_apps.account_manager_branches(customer_id, slot_number, fallback_account_manager, created_at, updated_at)
      VALUES (p_branch_id, 1, v_new_fallback, now(), now());
    END IF;
  END IF;

  PERFORM public.recalculate_account_manager_allocations_baseline();
  PERFORM public.apply_attendance_for_today();

  RETURN jsonb_build_object('status','success','changed', v_changed);
END;
$$;

-- set_account_manager_allocation: account-managers / update
CREATE OR REPLACE FUNCTION public.set_account_manager_allocation(
  p_user_id   uuid,
  p_branch_id integer,
  p_slot      integer,
  p_day       text,
  p_manager   uuid    DEFAULT NULL,
  p_clear     boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := COALESCE(auth.uid(), p_user_id);
  v_day text := lower(btrim(p_day));
  v_dow int;
  v_value uuid;
BEGIN
  -- Gate: account-managers / update. A company that has taken this away from a role gets a
  -- refusal here, not merely a hidden button.
  PERFORM qvm_new_apps.require_page_permission('account-managers', 'update');
  IF NOT EXISTS (
    SELECT 1 FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = v_uid
      AND (u.user_type = 185 OR lower(ur.list_data) IN ('admin','pricing supervisor'))
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  -- Qparts Admin reaches every branch; a Company Admin reaches their own and is refused the rest.
  PERFORM qvm_new_apps.assert_am_branch_in_scope(v_uid, p_branch_id);

  IF v_day NOT IN ('saturday','sunday','monday','tuesday','wednesday','thursday') THEN
    RETURN jsonb_build_object('success', false, 'error', format('%s is not a working day', p_day));
  END IF;
  IF p_slot NOT BETWEEN 1 AND 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Slot must be 1, 2 or 3');
  END IF;
  IF p_manager IS NOT NULL AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.user_data WHERE user_id = p_manager) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That user does not exist');
  END IF;

  -- The row has to exist before either branch of this can write to it: a branch that has never been
  -- through a recalculation has no allocation row at all.
  INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, calculated_at)
  SELECT p_branch_id, p_slot::smallint, now()
  WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.account_manager_allocations
                     WHERE customer_id = p_branch_id AND slot_number = p_slot::smallint);

  IF p_clear THEN
    DELETE FROM qvm_new_apps.account_manager_allocation_overrides
     WHERE customer_id = p_branch_id AND slot_number = p_slot::smallint AND day_key = v_day;

    -- Put the computed answer back in the cell, rather than leaving the hand-set one sitting there
    -- until something else happens to trigger a recalculation.
    v_dow := CASE v_day WHEN 'sunday' THEN 0 WHEN 'monday' THEN 1 WHEN 'tuesday' THEN 2
                        WHEN 'wednesday' THEN 3 WHEN 'thursday' THEN 4 ELSE 6 END;
    v_value := public._pick_available_manager_weekly(
                 p_branch_id, p_slot::smallint, public._date_for_weekday(current_date, v_dow));
  ELSE
    INSERT INTO qvm_new_apps.account_manager_allocation_overrides
      (customer_id, slot_number, day_key, account_manager, set_by, set_at)
    VALUES (p_branch_id, p_slot::smallint, v_day, p_manager, v_uid, now())
    ON CONFLICT (customer_id, slot_number, day_key) DO UPDATE
      SET account_manager = EXCLUDED.account_manager, set_by = EXCLUDED.set_by, set_at = now();
    v_value := p_manager;
  END IF;

  EXECUTE format(
    'UPDATE qvm_new_apps.account_manager_allocations SET %I = $1 WHERE customer_id = $2 AND slot_number = $3',
    v_day)
  USING v_value, p_branch_id, p_slot::smallint;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'branch_id', p_branch_id,
    'slot', p_slot,
    'day', v_day,
    'account_manager', v_value,
    'account_manager_name', (SELECT user_name FROM qvm_new_apps.user_data WHERE user_id = v_value),
    'is_override', NOT p_clear));
END $$;
