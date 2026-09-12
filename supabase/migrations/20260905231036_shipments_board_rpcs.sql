-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-1 — the board, by role.
--
-- Three audiences read the same shipments and must not read each other's: Qparts operations
-- sees everything, a vendor sees only what leaves its own branches, a driver sees only what
-- was handed to them. The scoping is decided here rather than by a filter the client sends,
-- because a filter the client sends is a filter the client can drop.
create or replace function qvm_new_apps.shipments_board(
  p_status integer default null,
  p_carrier integer default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0)
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
  v_is_driver boolean;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb; v_total bigint; v_counts jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select exists (
    select 1 from qvm_new_apps.user_data u
     join qvm_new_apps.list_data d on d.list_data_id = u.user_role
    where u.user_id = v_uid and d.list_id = 16 and d.list_data = 'Driver')
  into v_is_driver;

  if not (v_team or v_vendor is not null or v_is_driver) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with visible as (
    select s.*
      from qvm_new_apps.shipments s
      left join qvm_new_apps.pickups pk on pk.pickup_id = s.pickup_id
      left join qvm_new_apps.purchase_orders po on po.purchase_order_id = pk.purchase_order_id
     where (
             v_team
             -- A vendor's shipments are the ones leaving its branches or carrying its PO.
             or (v_vendor is not null and (
                   po.vendor_id = v_vendor
                   or s.pickup_vendor_branch_id in (
                        select vb.vendor_branch_id from qvm_new_apps.vendor_branches vb
                         where vb.vendor_id = v_vendor)))
             -- A driver's shipments are the ones assigned to them. Nothing else.
             or (v_is_driver and s.driver_id = v_uid)
           )
       and (p_status is null or s.status_id = p_status)
       and (p_carrier is null or s.carrier_id = p_carrier)
       and (v_q is null
            or s.shipment_code ilike '%'||v_q||'%'
            or coalesce(s.tracking_ref, '') ilike '%'||v_q||'%'
            or coalesce(s.dropoff_address, '') ilike '%'||v_q||'%'
            or coalesce(s.confirmed_order_id::text, '') ilike '%'||v_q||'%')
  )
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'shipment_id', v.shipment_id,
        'code', v.shipment_code,
        'order_id', v.confirmed_order_id,
        'delivery_id', v.delivery_id,
        'pickup_id', v.pickup_id,
        'carrier_id', v.carrier_id,
        'carrier', cd.list_data,
        'ship_type_id', v.shipment_type_id,
        'ship_type', td.list_data,
        'driver_id', v.driver_id,
        'driver', du.user_name,
        'driver_phone', null,
        'to', coalesce(v.dropoff_address, ''),
        'contact', v.dropoff_contact,
        'from', coalesce(v.pickup_address, vb.branch_name, ''),
        'eta', v.eta,
        'status_id', v.status_id,
        'status', sd.list_data,
        'price', v.price,
        'cost', v.cost,
        'tracking_ref', v.tracking_ref,
        'tracking_url', v.tracking_url,
        'items', (select count(*) from qvm_new_apps.shipment_items si where si.shipment_id = v.shipment_id),
        'created_at', v.created_at)
        order by v.created_at desc)
      from visible v
      left join qvm_new_apps.list_data cd on cd.list_data_id = v.carrier_id
      left join qvm_new_apps.list_data td on td.list_data_id = v.shipment_type_id
      left join qvm_new_apps.list_data sd on sd.list_data_id = v.status_id
      left join qvm_new_apps.user_data du on du.user_id = v.driver_id
      left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = v.pickup_vendor_branch_id
      limit greatest(p_limit, 1) offset greatest(p_offset, 0)
    ), '[]'::jsonb),
    (select count(*) from visible),
    -- The chips above the board count what this reader can see, not what exists.
    coalesce((
      select jsonb_object_agg(d.list_data, x.n)
        from (select v.status_id, count(*) n from visible v group by v.status_id) x
        join qvm_new_apps.list_data d on d.list_data_id = x.status_id
    ), '{}'::jsonb)
  into v_rows, v_total, v_counts;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', v_total, 'counts', v_counts,
    'role', case when v_team then 'team' when v_vendor is not null then 'vendor' else 'driver' end));
end
$function$;

revoke all on function qvm_new_apps.shipments_board(integer, integer, text, integer, integer) from public;
grant execute on function qvm_new_apps.shipments_board(integer, integer, text, integer, integer) to authenticated;
