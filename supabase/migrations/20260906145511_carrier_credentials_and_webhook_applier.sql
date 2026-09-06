-- Saving a carrier's key.
--
-- The token travels once, from the box somebody types it into to this function, and is never
-- sent back. No RPC selects it and RLS denies every web role; only the Edge Function, running
-- as service_role, ever reads it. That is what «server-side only» has to mean for a key that
-- differs per workspace — an environment variable cannot hold one per carrier per environment.
create or replace function qvm_new_apps.carrier_credentials_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_carrier integer := nullif(p_data->>'carrier_id','')::integer;
  v_env text := coalesce(nullif(btrim(coalesce(p_data->>'environment','')), ''), 'sandbox');
  v_token text := nullif(btrim(coalesce(p_data->>'api_token','')), '');
  v_url text := nullif(btrim(coalesce(p_data->>'api_base_url','')), '');
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_carrier is null then
    return jsonb_build_object('status', false, 'message', 'اختر شركة الشحن', 'data', null);
  end if;
  if v_env not in ('sandbox','production') then
    return jsonb_build_object('status', false, 'message', 'البيئة غير صحيحة', 'data', null);
  end if;

  insert into qvm_new_apps.carrier_credentials (carrier_id, environment, api_base_url, api_token, updated_by)
  values (v_carrier, v_env,
          coalesce(v_url, case when v_env = 'production'
                          then 'https://logistics.mrsool.co'
                          else 'https://logistics.staging.mrsool.co' end),
          v_token, auth.uid())
  on conflict (carrier_id, environment) do update set
    api_base_url = coalesce(excluded.api_base_url, qvm_new_apps.carrier_credentials.api_base_url),
    -- A blank box means «leave it alone», not «erase it». Somebody editing the base URL
    -- should not have to retype a key they cannot see.
    api_token    = coalesce(excluded.api_token, qvm_new_apps.carrier_credentials.api_token),
    updated_by   = auth.uid(),
    updated_at   = now();

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

-- Which environment a carrier is live on. Exactly one per carrier can be active, because a
-- shipment must not be sent to sandbox and tracked in production.
create or replace function qvm_new_apps.carrier_set_environment(p_carrier integer, p_env text)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  update qvm_new_apps.carrier_credentials set is_active = (environment = p_env), updated_at = now()
   where carrier_id = p_carrier;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

-- What a webhook does when it lands. Called by the Edge Function after it has verified the
-- signature — the rule about not moving a shipment backwards lives here, next to the data,
-- so a replayed or out-of-order delivery cannot rewind a shipment that already arrived.
create or replace function qvm_new_apps.carrier_status_apply(
  p_tracking_ref text, p_carrier_status text, p_payload jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_ship record;
  v_map record;
  v_cur_rank integer;
begin
  select * into v_ship from qvm_new_apps.shipments
   where tracking_ref = p_tracking_ref order by created_at desc limit 1;
  if v_ship is null then
    return jsonb_build_object('status', false, 'message', 'shipment not found', 'data', null);
  end if;

  select * into v_map from qvm_new_apps.carrier_status_map
   where carrier_id = v_ship.carrier_id and carrier_status = p_carrier_status;
  if v_map is null then
    -- An unknown status is recorded rather than dropped: the raw word is kept on the shipment
    -- so somebody can see what arrived and add the mapping row.
    update qvm_new_apps.shipments
       set carrier_status = p_carrier_status, carrier_payload = p_payload, updated_at = now()
     where shipment_id = v_ship.shipment_id;
    return jsonb_build_object('status', false,
      'message', 'unmapped carrier status: ' || p_carrier_status, 'data', null);
  end if;

  select rank into v_cur_rank from qvm_new_apps.carrier_status_map
   where carrier_id = v_ship.carrier_id and carrier_status = coalesce(v_ship.carrier_status, '');

  update qvm_new_apps.shipments
     set carrier_status = p_carrier_status, carrier_payload = p_payload, updated_at = now()
   where shipment_id = v_ship.shipment_id;

  -- Webhooks arrive out of order and get retried. Only a status further along the journey
  -- moves the shipment; an older one updates the raw record and nothing else.
  if v_cur_rank is null or v_map.rank > v_cur_rank then
    perform qvm_new_apps.shipment_set_status(
      v_ship.shipment_id,
      (select list_data from qvm_new_apps.list_data where list_data_id = v_map.our_status_id),
      'Mrsool: ' || p_carrier_status, null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'shipment_id', v_ship.shipment_id, 'moved', (v_cur_rank is null or v_map.rank > v_cur_rank)));
end
$function$;

revoke all on function qvm_new_apps.carrier_credentials_save(jsonb) from public;
revoke all on function qvm_new_apps.carrier_set_environment(integer, text) from public;
revoke all on function qvm_new_apps.carrier_status_apply(text, text, jsonb) from public;
grant execute on function qvm_new_apps.carrier_credentials_save(jsonb) to authenticated;
grant execute on function qvm_new_apps.carrier_set_environment(integer, text) to authenticated;
grant execute on function qvm_new_apps.carrier_status_apply(text, text, jsonb) to service_role;
