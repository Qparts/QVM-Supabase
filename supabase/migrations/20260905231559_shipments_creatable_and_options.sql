-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- What «إنشاء شحنة» can be created from, and the options the form needs.
--
-- Only notes that do not have a shipment yet: offering one that already has a van on the way
-- is how the same parts end up on the board twice.
create or replace function qvm_new_apps.shipments_creatable()
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
    'deliveries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'delivery_id', d.delivery_id,
               'order_id', d.confirmed_order_id,
               'date', d.delivery_date,
               'client_po', d.client_po,
               'items', (select count(*) from qvm_new_apps.delivery_items di
                          where di.delivery_id = d.delivery_id))
             order by d.delivery_date desc nulls last)
        from qvm_new_apps.deliveries d
       where not exists (select 1 from qvm_new_apps.shipments s where s.delivery_id = d.delivery_id)
         and exists (select 1 from qvm_new_apps.delivery_items di where di.delivery_id = d.delivery_id)
    ), '[]'::jsonb),
    'pickups', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pickup_id', pk.pickup_id,
               'purchase_order_id', pk.purchase_order_id,
               'date', pk.pickup_date,
               'vendor', v.vendor_name,
               'branch', vb.branch_name,
               'items', (select count(*) from qvm_new_apps.pickup_items pi
                          where pi.pickup_id = pk.pickup_id))
             order by pk.pickup_date desc nulls last)
        from qvm_new_apps.pickups pk
        left join qvm_new_apps.purchase_orders po on po.purchase_order_id = pk.purchase_order_id
        left join qvm_new_apps.vendors v on v.vendor_id = po.vendor_id
        left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = po.vendor_branch_id
       where not exists (select 1 from qvm_new_apps.shipments s where s.pickup_id = pk.pickup_id)
    ), '[]'::jsonb),
    -- Only what settings say is switched on. The dropdown and the server agree because they
    -- are the same answer, read once.
    'carriers', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.list_data_id, 'name', d.list_data,
                                          'pricing_mode', s.pricing_mode, 'flat_fee', s.flat_fee)
             order by s.sort_order)
        from qvm_new_apps.shipping_settings s
        join qvm_new_apps.list_data d on d.list_data_id = s.carrier_id
       where s.is_enabled), '[]'::jsonb),
    'ship_types', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.list_data_id, 'name', d.list_data)
             order by s.sort_order)
        from qvm_new_apps.shipping_settings s
        join qvm_new_apps.list_data d on d.list_data_id = s.ship_type_id
       where s.is_enabled), '[]'::jsonb),
    'statuses', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.list_data_id, 'name', d.list_data)
             order by d.list_data_id)
        from qvm_new_apps.list_data d
        join qvm_new_apps.lists l on l.list_id = d.list_id
       where l.list_name = 'shipment_status'), '[]'::jsonb),
    'addresses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'address_id', a.address_id, 'label', a.label,
               'line', a.address_line, 'city', a.city,
               'contact', a.contact_name, 'phone', a.contact_phone))
        from qvm_new_apps.customer_addresses a
       where coalesce(a.is_active, true) and coalesce(a.receives_shipments, true)), '[]'::jsonb),
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', u.user_id, 'name', u.user_name))
        from qvm_new_apps.user_data u
        join qvm_new_apps.list_data d on d.list_data_id = u.user_role
       where d.list_id = 16 and d.list_data = 'Driver' and u.deleted_at is null), '[]'::jsonb)));
end
$function$;

revoke all on function qvm_new_apps.shipments_creatable() from public;
grant execute on function qvm_new_apps.shipments_creatable() to authenticated;
