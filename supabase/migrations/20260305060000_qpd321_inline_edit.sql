-- QPD-321: Inline Editing RPCs
-- Security: authenticated internal users only

-- Update quotation_items fields (part_description, part_number, alternative_part_number, part_category)
create or replace function public.update_quotation_item_inline(
  p_quotation_item_id int,
  p_part_description text default null,
  p_part_number text default null,
  p_alternative_part_number text default null,
  p_part_category int default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = qvm_new_apps, public, pg_temp
as $$
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
    part_category = coalesce(p_part_category, qi.part_category),
    item_status = CASE
      WHEN NULLIF(p_part_number, '') IS NOT NULL
           AND NULLIF(qi.part_number, '') IS NULL
           AND qi.item_status = 236
      THEN 235
      ELSE qi.item_status
    END
  where quotation_item_id = p_quotation_item_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'No changes applied';
  end if;

  -- Log the transition from Extract PN to Ready For Quotation if it happened
  IF NULLIF(p_part_number, '') IS NOT NULL THEN
    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
    SELECT p_quotation_item_id, 235, v_uid, now()
    WHERE EXISTS (
      SELECT 1 FROM qvm_new_apps.quotation_items qi2
      WHERE qi2.quotation_item_id = p_quotation_item_id
        AND qi2.item_status = 235
        AND qi2.part_number IS NOT NULL
        AND trim(qi2.part_number) <> ''
    )
    ON CONFLICT DO NOTHING;
  END IF;

  return jsonb_build_object('status', 'success', 'message', 'quotation_item updated');
end;
$$;

revoke execute on function public.update_quotation_item_inline(int, text, text, text, int) from public, anon;
grant execute on function public.update_quotation_item_inline(int, text, text, text, int) to authenticated;

-- Update confirmed_items fields (approved_qty, return_type)
create or replace function public.update_confirmed_item_inline(
  p_quotation_item_id int,
  p_approved_qty int default null,
  p_return_type int default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = qvm_new_apps, public, pg_temp
as $$
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
$$;

revoke execute on function public.update_confirmed_item_inline(int, int, int) from public, anon;
grant execute on function public.update_confirmed_item_inline(int, int, int) to authenticated;

-- Update purchase_orders payment account by confirmed_order_id
create or replace function public.update_purchase_account_inline(
  p_confirmed_order_id int,
  p_payment_account int
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = qvm_new_apps, public, pg_temp
as $$
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

  perform 1 from list_data where list_data_id = p_payment_account;
  if not found then
    raise exception 'Invalid payment_account (list_data_id %) provided', p_payment_account;
  end if;

  update purchase_orders po
  set payment_account = p_payment_account
  where po.confirmed_order_id = p_confirmed_order_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'purchase_orders row for confirmed_order_id % not found', p_confirmed_order_id;
  end if;

  return jsonb_build_object('status', 'success', 'message', 'purchase_account updated');
end;
$$;

revoke execute on function public.update_purchase_account_inline(int, int) from public, anon;
grant execute on function public.update_purchase_account_inline(int, int) to authenticated;

-- Reference data for inline editing (distinct values in use)
create or replace function public.get_inline_edit_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = qvm_new_apps, public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Unauthorized';
  end if;

  return jsonb_build_object(
    'part_categories', coalesce(
      (
        select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'label', ld.list_data) order by ld.list_data)
        from list_data ld
        where exists (select 1 from quotation_items qi where qi.part_category = ld.list_data_id)
      ), '[]'::jsonb
    ),
    'return_types', coalesce(
      (
        select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'label', ld.list_data) order by ld.list_data)
        from list_data ld
        where exists (select 1 from confirmed_items ci where ci.return_type = ld.list_data_id)
      ), '[]'::jsonb
    ),
    'payment_accounts', coalesce(
      (
        select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'label', ld.list_data) order by ld.list_data)
        from list_data ld
        where exists (select 1 from purchase_orders po where po.payment_account = ld.list_data_id)
      ), '[]'::jsonb
    )
  );
end;
$$;

revoke execute on function public.get_inline_edit_reference_data() from public, anon;
grant execute on function public.get_inline_edit_reference_data() to authenticated;
