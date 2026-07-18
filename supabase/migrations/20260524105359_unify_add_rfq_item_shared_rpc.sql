-- Synced from QVM/test branch applied migration history (version 20260524105359, name: unify_add_rfq_item_shared_rpc)
drop function if exists public.add_rfq_item(integer, text, text, integer, integer, text, text);

create or replace function public.add_rfq_item(
  p_quotation_id integer,
  p_part_number text,
  p_part_description text,
  p_quantity integer,
  p_brand_class integer,
  p_part_photo text default null,
  p_note_description text default null,
  p_main_brand integer default null,
  p_model text default null,
  p_year text default null,
  p_is_internal_note boolean default false,
  p_require_internal_user boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, qvm_new_apps
as $$
declare
  v_uid uuid;
  v_user_type integer;
  v_customer_id integer;
  v_vin text;
  v_main_brand integer;
  v_model text;
  v_year text;
  v_new_item_id integer;
  v_item_status integer := 15;
  v_brand_class_name text;
  v_main_brand_name text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  if coalesce(p_require_internal_user, false) then
    select ud.user_type
    into v_user_type
    from qvm_new_apps.user_data ud
    where ud.user_id = v_uid;

    if v_user_type is distinct from 185 then
      raise exception 'Access denied: Internal users only';
    end if;
  end if;

  if p_quotation_id is null or p_quotation_id <= 0 then
    raise exception 'Missing or invalid input (quotation_id)';
  end if;

  perform 1
  from qvm_new_apps.quotations q
  where q.quotation_id = p_quotation_id;

  if not found then
    raise exception 'quotation_id % not found', p_quotation_id;
  end if;

  if (p_part_number is null or btrim(p_part_number) = '')
    and (p_part_description is null or btrim(p_part_description) = '') then
    raise exception 'Missing input - please provide part number or part description';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Missing or invalid input (quantity)';
  end if;

  if p_brand_class is null or p_brand_class <= 0 then
    raise exception 'Missing or invalid input (brand_class)';
  end if;

  select ld.list_data
  into v_brand_class_name
  from qvm_new_apps.list_data ld
  where ld.list_data_id = p_brand_class;

  if v_brand_class_name is null then
    raise exception 'Invalid brand class - does not exist in system';
  end if;

  select
    qi.customer_id,
    qi.vin,
    qi.main_brand,
    qi.model,
    qi.year
  into
    v_customer_id,
    v_vin,
    v_main_brand,
    v_model,
    v_year
  from qvm_new_apps.quotation_items qi
  where qi.quotation_id = p_quotation_id
  order by qi.quotation_item_id asc
  limit 1;

  if v_customer_id is null then
    raise exception 'RFQ has no existing items to derive branch info';
  end if;

  if coalesce(p_require_internal_user, false) then
    if p_main_brand is null or p_main_brand <= 0 then
      raise exception 'Car Brand is required';
    end if;

    select ld.list_data
    into v_main_brand_name
    from qvm_new_apps.list_data ld
    where ld.list_data_id = p_main_brand;

    if v_main_brand_name is null then
      raise exception 'Invalid main_brand (list_data_id %) provided', p_main_brand;
    end if;

    perform 1
    from qvm_new_apps.client_branches cb
    where cb.customer_id = v_customer_id;

    if not found then
      raise exception 'Invalid customer_id % derived from quotation %', v_customer_id, p_quotation_id;
    end if;

    select qi.vin
    into v_vin
    from qvm_new_apps.quotation_items qi
    where qi.quotation_id = p_quotation_id
      and qi.main_brand = p_main_brand
      and qi.vin is not null
      and btrim(qi.vin) <> ''
    order by qi.quotation_item_id asc
    limit 1;

    v_main_brand := p_main_brand;
    v_model := nullif(btrim(coalesce(p_model, '')), '');
    v_year := nullif(btrim(coalesce(p_year, '')), '');
  else
    if v_main_brand is not null then
      select ld.list_data
      into v_main_brand_name
      from qvm_new_apps.list_data ld
      where ld.list_data_id = v_main_brand;
    end if;
  end if;

  insert into qvm_new_apps.quotation_items (
    quotation_id,
    part_number,
    part_description,
    quantity,
    brand_class,
    part_photo,
    item_status,
    customer_id,
    vin,
    main_brand,
    model,
    year,
    created_at,
    updated_at
  )
  values (
    p_quotation_id,
    nullif(btrim(coalesce(p_part_number, '')), ''),
    nullif(btrim(coalesce(p_part_description, '')), ''),
    p_quantity,
    p_brand_class,
    nullif(btrim(coalesce(p_part_photo, '')), ''),
    v_item_status,
    v_customer_id,
    v_vin,
    v_main_brand,
    v_model,
    v_year,
    now(),
    now()
  )
  returning quotation_item_id into v_new_item_id;

  insert into qvm_new_apps.status_logs (
    quotation_item_id,
    item_status,
    status_changed_by,
    created_at
  )
  values (
    v_new_item_id,
    v_item_status,
    v_uid,
    now()
  );

  if p_note_description is not null and btrim(p_note_description) <> '' then
    insert into qvm_new_apps.notes (
      note_type,
      type_id,
      note_description,
      user_id,
      is_internal,
      created_at,
      updated_at
    )
    values (
      'quotation_items',
      v_new_item_id,
      btrim(p_note_description),
      v_uid,
      coalesce(p_is_internal_note, false),
      now(),
      now()
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'status', 'success',
    'message', 'Item added',
    'quotation_item_id', v_new_item_id,
    'item_status_id', v_item_status,
    'item_status', 'New RFQ',
    'brand_class_id', p_brand_class,
    'brand_class', v_brand_class_name,
    'main_brand_id', v_main_brand,
    'main_brand', v_main_brand_name
  );
end;
$$;

revoke execute on function public.add_rfq_item(
  integer,
  text,
  text,
  integer,
  integer,
  text,
  text,
  integer,
  text,
  text,
  boolean,
  boolean
) from public, anon;

grant execute on function public.add_rfq_item(
  integer,
  text,
  text,
  integer,
  integer,
  text,
  text,
  integer,
  text,
  text,
  boolean,
  boolean
) to authenticated;

create or replace function public.add_rfq_item_inline(
  p_quotation_id int,
  p_customer_id int default null,
  p_part_number text default null,
  p_part_description text default null,
  p_quantity int default 1,
  p_brand_class int default null,
  p_main_brand int default null,
  p_model text default null,
  p_year text default null,
  p_part_photo text default null,
  p_initial_note text default null,
  p_is_internal_note boolean default false
)
returns jsonb
language sql
security definer
set search_path = public, qvm_new_apps
as $$
  select public.add_rfq_item(
    p_quotation_id => p_quotation_id,
    p_part_number => p_part_number,
    p_part_description => p_part_description,
    p_quantity => p_quantity,
    p_brand_class => p_brand_class,
    p_part_photo => p_part_photo,
    p_note_description => p_initial_note,
    p_main_brand => p_main_brand,
    p_model => p_model,
    p_year => p_year,
    p_is_internal_note => p_is_internal_note,
    p_require_internal_user => true
  );
$$;

revoke execute on function public.add_rfq_item_inline(
  int,
  int,
  text,
  text,
  int,
  int,
  int,
  text,
  text,
  text,
  text,
  boolean
) from public, anon;

grant execute on function public.add_rfq_item_inline(
  int,
  int,
  text,
  text,
  int,
  int,
  int,
  text,
  text,
  text,
  text,
  boolean
) to authenticated;;
