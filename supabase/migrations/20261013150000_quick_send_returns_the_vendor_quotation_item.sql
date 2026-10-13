-- The vendor webhooks carry the vendor quotation item (quotation_vendor_items.cost_id) on every
-- item. Quick Send builds its payload from this function, so the function now returns each
-- vendor's cost_id for the line, and the line's id on the item.
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
      -- A line re-issued for a cancelled quantity is not offered back to the vendor who cancelled it.
      and not exists (select 1 from qvm_new_apps.quotation_item_cancellations c
                       where c.reissued_item_id = p_quotation_item_id and c.vendor_id = qv.vendor_id)
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
      'access_token', r.access_token,
      -- The vendor's row for this line, new or already there: what their price is written to.
      'cost_id', (select qvi.cost_id from qvm_new_apps.quotation_vendor_items qvi
                   where qvi.quotation_item_id = p_quotation_item_id
                     and qvi.quotation_vendor_id = r.quotation_vendor_id)
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
      'quotation_item_id', p_quotation_item_id,
      'part_number', coalesce(v_part_number, ''), 'part_description', coalesce(v_part_desc, ''),
      'class', coalesce(v_class, ''), 'qty', coalesce(v_qty, 1)
    )),
    'created', v_created,
    'created_count', v_count
  );
end $function$;

notify pgrst, 'reload schema';
