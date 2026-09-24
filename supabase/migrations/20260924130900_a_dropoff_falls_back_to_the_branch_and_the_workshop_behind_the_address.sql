-- A dropoff falls back to the branch, and then to the workshop behind the address.
--
-- Mrsool refuses a shipment without a point at both ends, and every shipment on the platform was
-- failing that check on the dropoff. It looked like missing data: `customer_addresses` has
-- `geo_lat` on none of its rows.
--
-- It was missing *lookups*. An address belongs to a client branch, a branch belongs to a
-- workshop, and both of those carry a point — `client_branches` on 7 rows of 7,
-- `client_workshops` on 6 of 6. The payload only ever asked the address. All four addresses on
-- this database resolve the moment you follow the chain.
--
-- Note the join key: `client_branches` is keyed by `customer_id`, not by `list_data_id`. That
-- confusion has already cost this codebase one real bug, where three branches all carried
-- `list_data_id = 1` and a per-branch toggle silently collapsed onto a single row.
--
-- Ordered nearest-first. An address's own point is the delivery door; the branch is the site;
-- the workshop is the site's parent. Falling back up that order loses precision gradually rather
-- than jumping to the least specific thing that happens to be filled in.
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
      'latitude',  coalesce(s.dropoff_lat, a.geo_lat, cb.location_lat, cw.location_lat)::text,
      'longitude', coalesce(s.dropoff_lng, a.geo_lng, cb.location_lng, cw.location_lng)::text,
      'address',   coalesce(nullif(s.dropoff_address,''), a.address_line, cb.branch_name)),
    -- Where the point came from, so «why is this delivering to the wrong gate» has an answer
    -- on the screen instead of in somebody's head.
    'dropoff_source', case
      when s.dropoff_lat is not null then 'shipment'
      when a.geo_lat  is not null then 'address'
      when cb.location_lat is not null then 'branch'
      when cw.location_lat is not null then 'workshop'
      else null end,
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
  -- `customer_id` is the branch key here, not `list_data_id`.
  left join qvm_new_apps.client_branches  cb on cb.customer_id = a.client_branch_id
  left join qvm_new_apps.client_workshops cw on cw.workshop_id = cb.workshop_id
  where s.shipment_id = p_shipment_id;

  return coalesce(v, '{}'::jsonb);
end
$function$;
