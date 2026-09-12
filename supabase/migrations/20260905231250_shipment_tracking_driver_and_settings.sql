-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-5 — «تتبع الشحنة».
--
-- Logged-in and scoped, same decision as QNEW-121: no anonymous link in v1. The timeline is
-- the status log, which is why the log had to be the one everything else already writes to.
create or replace function qvm_new_apps.shipment_track(
  p_shipment_id bigint default null, p_order_id integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_id bigint := p_shipment_id;
  v_ship record;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if v_id is null and p_order_id is not null then
    select s.shipment_id into v_id from qvm_new_apps.shipments s
     where s.confirmed_order_id = p_order_id
     order by s.created_at desc limit 1;
  end if;

  if v_id is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
  end if;

  select s.*, cd.list_data as carrier_name, sd.list_data as status_name,
         du.user_name as driver_name
    into v_ship
    from qvm_new_apps.shipments s
    left join qvm_new_apps.list_data cd on cd.list_data_id = s.carrier_id
    left join qvm_new_apps.list_data sd on sd.list_data_id = s.status_id
    left join qvm_new_apps.user_data du on du.user_id = s.driver_id
   where s.shipment_id = v_id;

  if v_ship is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
  end if;

  -- A shipment somebody cannot see on the board is a shipment they cannot track either.
  if not (v_team
          or (v_vendor is not null and exists (
                select 1 from qvm_new_apps.vendor_branches vb
                 where vb.vendor_branch_id = v_ship.pickup_vendor_branch_id
                   and vb.vendor_id = v_vendor))
          or v_ship.driver_id = v_uid) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'shipment_id', v_ship.shipment_id,
    'code', v_ship.shipment_code,
    'order_id', v_ship.confirmed_order_id,
    'carrier', v_ship.carrier_name,
    'driver', v_ship.driver_name,
    'status', v_ship.status_name,
    'eta', v_ship.eta,
    'to', v_ship.dropoff_address,
    'from', v_ship.pickup_address,
    'tracking_ref', v_ship.tracking_ref,
    'tracking_url', v_ship.tracking_url,
    'pod_receiver', v_ship.pod_receiver,
    'pod_photo_url', v_ship.pod_photo_url,
    'failure_reason', v_ship.failure_reason,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('name', ci.final_part_number, 'qty', si.qty))
        from qvm_new_apps.shipment_items si
        left join qvm_new_apps.delivery_items di on di.delivery_item_id = si.delivery_item_id
        left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = di.confirmed_item_id
       where si.shipment_id = v_id), '[]'::jsonb),
    'timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
               'status', d.list_data, 'at', sl.created_at, 'by', u.user_name)
             order by sl.created_at)
        from qvm_new_apps.status_logs sl
        left join qvm_new_apps.list_data d on d.list_data_id = sl.item_status
        left join qvm_new_apps.user_data u on u.user_id = sl.status_changed_by
       where sl.shipment_id = v_id), '[]'::jsonb)));
end
$function$;

-- QNEW-124 S-4 — the driver's own actions. A driver can only move their own shipment, and
-- only forward: the sequence is the job, and letting it be set arbitrarily from a phone is
-- how a shipment ends up «delivered» before it was collected.
create or replace function qvm_new_apps.shipment_driver_action(
  p_shipment_id bigint, p_action text, p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_ship record;
  v_next text;
begin
  select * into v_ship from qvm_new_apps.shipments where shipment_id = p_shipment_id;
  if v_ship is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if v_ship.driver_id is distinct from v_uid then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_next := case p_action
    when 'accept'     then 'Dispatched'
    when 'picked_up'  then 'Picked Up'
    when 'in_transit' then 'In Transit'
    when 'delivered'  then 'Delivered'
    when 'failed'     then 'Delivery Failed'
    else null end;

  if v_next is null then
    return jsonb_build_object('status', false, 'message', 'unknown action', 'data', null);
  end if;

  if p_action = 'delivered' then
    -- Proof of delivery is the point of the step. Without a receiver's name there is nothing
    -- to show the workshop when they say it never arrived.
    if nullif(btrim(coalesce(p_data->>'receiver','')), '') is null then
      return jsonb_build_object('status', false, 'message', 'اسم المستلم مطلوب', 'data', null);
    end if;
    update qvm_new_apps.shipments set
      pod_receiver  = btrim(p_data->>'receiver'),
      pod_signature = nullif(btrim(coalesce(p_data->>'signature','')), ''),
      pod_photo_url = nullif(btrim(coalesce(p_data->>'photo_url','')), '')
     where shipment_id = p_shipment_id;

    -- The delivery note carries the signature too: it is the document the customer signs and
    -- the rest of the system already reads it from there.
    if v_ship.delivery_id is not null
       and nullif(btrim(coalesce(p_data->>'signature','')), '') is not null then
      update qvm_new_apps.deliveries
         set signature = btrim(p_data->>'signature')
       where delivery_id = v_ship.delivery_id and signature is null;
    end if;
  end if;

  if p_action = 'picked_up' and v_ship.pickup_id is not null then
    update qvm_new_apps.pickups set pickup_date = coalesce(pickup_date, now())
     where pickup_id = v_ship.pickup_id;
  end if;

  perform qvm_new_apps.shipment_set_status(
    p_shipment_id, v_next, nullif(btrim(coalesce(p_data->>'reason','')), ''), v_uid);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('status', v_next));
end
$function$;

-- S-3 — the settings screen reads and writes through these; the credential table is never
-- exposed by either, so a token cannot reach a browser even by mistake.
create or replace function qvm_new_apps.shipping_settings_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'internal_drivers_enabled',
      (select internal_drivers_enabled from qvm_new_apps.shipping_config where id),
    'carriers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'setting_id', s.setting_id, 'id', s.carrier_id, 'name', d.list_data,
               'enabled', s.is_enabled, 'pricing_mode', s.pricing_mode, 'flat_fee', s.flat_fee)
             order by s.sort_order)
        from qvm_new_apps.shipping_settings s
        join qvm_new_apps.list_data d on d.list_data_id = s.carrier_id
       where s.carrier_id is not null), '[]'::jsonb),
    'types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'setting_id', s.setting_id, 'id', s.ship_type_id, 'name', d.list_data,
               'enabled', s.is_enabled)
             order by s.sort_order)
        from qvm_new_apps.shipping_settings s
        join qvm_new_apps.list_data d on d.list_data_id = s.ship_type_id
       where s.ship_type_id is not null), '[]'::jsonb),
    -- Whether a carrier is configured at all, never what with.
    'credentials', coalesce((
      select jsonb_agg(jsonb_build_object(
               'carrier_id', c.carrier_id, 'environment', c.environment,
               'configured', c.api_token is not null,
               'last_test_at', c.last_test_at, 'last_test_ok', c.last_test_ok,
               'last_test_note', c.last_test_note))
        from qvm_new_apps.carrier_credentials c), '[]'::jsonb),
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', u.user_id, 'name', u.user_name, 'email', u.email))
        from qvm_new_apps.user_data u
        join qvm_new_apps.list_data d on d.list_data_id = u.user_role
       where d.list_id = 16 and d.list_data = 'Driver' and u.deleted_at is null), '[]'::jsonb)));
end
$function$;

create or replace function qvm_new_apps.shipping_settings_save(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare r jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if p_patch ? 'internal_drivers_enabled' then
    update qvm_new_apps.shipping_config
       set internal_drivers_enabled = (p_patch->>'internal_drivers_enabled')::boolean,
           updated_by = auth.uid(), updated_at = now()
     where id;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_patch->'settings', '[]'::jsonb)) loop
    update qvm_new_apps.shipping_settings s set
      is_enabled   = coalesce((r->>'enabled')::boolean, s.is_enabled),
      pricing_mode = coalesce(nullif(r->>'pricing_mode',''), s.pricing_mode),
      flat_fee     = case when r ? 'flat_fee' then nullif(btrim(coalesce(r->>'flat_fee','')),'')::numeric
                          else s.flat_fee end,
      updated_by = auth.uid(), updated_at = now()
     where s.setting_id = (r->>'setting_id')::bigint;
  end loop;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

revoke all on function qvm_new_apps.shipment_track(bigint, integer) from public;
revoke all on function qvm_new_apps.shipment_driver_action(bigint, text, jsonb) from public;
revoke all on function qvm_new_apps.shipping_settings_get() from public;
revoke all on function qvm_new_apps.shipping_settings_save(jsonb) from public;
grant execute on function qvm_new_apps.shipment_track(bigint, integer) to authenticated;
grant execute on function qvm_new_apps.shipment_driver_action(bigint, text, jsonb) to authenticated;
grant execute on function qvm_new_apps.shipping_settings_get() to authenticated;
grant execute on function qvm_new_apps.shipping_settings_save(jsonb) to authenticated;
