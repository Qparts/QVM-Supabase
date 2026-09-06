-- Coordinates on the shipment itself.
--
-- Mrsool prices and dispatches on latitude/longitude, not on written addresses. They are
-- copied onto the shipment the same way the address text is: the record of where this
-- particular van was sent, which must not change when somebody later edits a branch.
alter table qvm_new_apps.shipments
  add column if not exists pickup_lat  numeric,
  add column if not exists pickup_lng  numeric,
  add column if not exists dropoff_lat numeric,
  add column if not exists dropoff_lng numeric;

-- Everything the carrier call needs, in one read, with the coordinates resolved from
-- whichever record actually holds them.
create or replace function qvm_new_apps.shipment_carrier_payload(p_shipment_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v jsonb;
begin
  select jsonb_build_object(
    'shipment_id', s.shipment_id,
    'code', s.shipment_code,
    'carrier_id', s.carrier_id,
    'carrier', cd.list_data,
    'order_id', s.confirmed_order_id,
    'tracking_ref', s.tracking_ref,
    'description', coalesce(nullif(s.notes,''),
                            'قطع غيار — ' || coalesce(s.shipment_code,'')),
    'shipment_value', coalesce(s.price, 0),
    -- The vendor branch is where a pickup starts; a delivery starts from us, and the
    -- shipment's own pickup fields are what says where that is.
    'pickup', jsonb_build_object(
      'latitude',  coalesce(s.pickup_lat,  vb.location_lat)::text,
      'longitude', coalesce(s.pickup_lng,  vb.location_lng)::text,
      'address',   coalesce(nullif(s.pickup_address,''), vb.address, vb.branch_name)),
    'dropoff', jsonb_build_object(
      'latitude',  coalesce(s.dropoff_lat, a.geo_lat)::text,
      'longitude', coalesce(s.dropoff_lng, a.geo_lng)::text,
      'address',   coalesce(nullif(s.dropoff_address,''), a.address_line)),
    'buyer', jsonb_build_object(
      'phone',     coalesce(nullif(s.dropoff_phone,''), a.contact_phone, vb.phone),
      'full_name', coalesce(nullif(s.dropoff_contact,''), a.contact_name)),
    'store', jsonb_build_object(
      'name',  coalesce(v.vendor_name, 'Qparts'),
      'phone', coalesce(nullif(s.pickup_phone,''), vb.phone))
  )
  into v
  from qvm_new_apps.shipments s
  left join qvm_new_apps.list_data cd on cd.list_data_id = s.carrier_id
  left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = s.pickup_vendor_branch_id
  left join qvm_new_apps.vendors v on v.vendor_id = vb.vendor_id
  left join qvm_new_apps.customer_addresses a on a.address_id = s.dropoff_address_id
  where s.shipment_id = p_shipment_id;

  return coalesce(v, '{}'::jsonb);
end
$function$;

-- What comes back from the carrier, written down. Separate from the status path because
-- creating an order and being told its status later are two different events.
create or replace function qvm_new_apps.shipment_carrier_result(
  p_shipment_id bigint, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
begin
  update qvm_new_apps.shipments set
    tracking_ref   = coalesce(nullif(btrim(coalesce(p_data->>'tracking_ref','')), ''), tracking_ref),
    tracking_url   = coalesce(nullif(btrim(coalesce(p_data->>'tracking_url','')), ''), tracking_url),
    carrier_status = coalesce(nullif(btrim(coalesce(p_data->>'carrier_status','')), ''), carrier_status),
    carrier_payload= coalesce(p_data->'payload', carrier_payload),
    -- A live-priced carrier is the authority on what it charges us.
    cost           = coalesce(nullif(btrim(coalesce(p_data->>'cost','')), '')::numeric, cost),
    eta            = coalesce(nullif(btrim(coalesce(p_data->>'eta','')), '')::timestamptz, eta),
    updated_at     = now()
   where shipment_id = p_shipment_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

revoke all on function qvm_new_apps.shipment_carrier_payload(bigint) from public;
revoke all on function qvm_new_apps.shipment_carrier_result(bigint, jsonb) from public;
grant execute on function qvm_new_apps.shipment_carrier_payload(bigint) to service_role;
grant execute on function qvm_new_apps.shipment_carrier_result(bigint, jsonb) to service_role;
