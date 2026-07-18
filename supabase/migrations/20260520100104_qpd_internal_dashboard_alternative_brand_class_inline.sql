-- Synced from QVM/test branch applied migration history (version 20260520100104, name: qpd_internal_dashboard_alternative_brand_class_inline)
-- Allow internal dashboard inline editing of alternative_brand_class

create or replace function public.update_quotation_item_inline(
  p_quotation_item_id int,
  p_part_description text default null,
  p_part_number text default null,
  p_alternative_part_number text default null,
  p_alternative_brand_class int default null,
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

  if p_alternative_brand_class is not null then
    perform 1 from list_data where list_data_id = p_alternative_brand_class;
    if not found then
      raise exception 'Invalid alternative_brand_class (list_data_id %) provided', p_alternative_brand_class;
    end if;
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

  if coalesce(nullif(coalesce(p_part_description, v_current_desc), ''), '') = ''
     and coalesce(nullif(coalesce(p_part_number, v_current_num), ''), '') = '' then
    raise exception 'Part Description and Part Number cannot both be empty';
  end if;

  update quotation_items qi
  set
    part_description = coalesce(p_part_description, qi.part_description),
    part_number = coalesce(p_part_number, qi.part_number),
    alternative_part_number = coalesce(p_alternative_part_number, qi.alternative_part_number),
    alternative_brand_class = coalesce(p_alternative_brand_class, qi.alternative_brand_class),
    part_category = coalesce(p_part_category, qi.part_category)
  where quotation_item_id = p_quotation_item_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'No changes applied';
  end if;

  return jsonb_build_object('status', 'success', 'message', 'quotation_item updated');
end;
$$;

revoke execute on function public.update_quotation_item_inline(int, text, text, text, int, int) from public, anon;
grant execute on function public.update_quotation_item_inline(int, text, text, text, int, int) to authenticated;
;
