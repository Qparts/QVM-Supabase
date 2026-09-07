-- A client opening the Shipment Board was told «forbidden».
--
-- The board admits three kinds of reader — team, vendor, driver — and a Client Admin is none of
-- them. But the page is in their sidebar, and its empty state is written to them in so many
-- words: «Shipments appear here once operations dispatches them». So the menu promised
-- something the function refused, and the customer got a bare error where the answer to «where
-- are my parts» was supposed to be.
--
-- The scope is the one every other customer-facing screen already uses: user_data.user_company,
-- resolved through the order the shipment is carrying. Decided here rather than passed in, so
-- nothing on the client side can widen it.
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
  v_company integer;
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

  -- Being a driver is the more specific fact about a person than being on the team, so it
  -- decides what they see. Otherwise every driver reads as team and the board stops being
  -- «my jobs» the moment somebody is both.
  if v_is_driver then
    v_team := false;
    v_vendor := null;
  end if;

  -- Customer is the fallback identity, not an additional one: somebody who is already team,
  -- vendor or driver is being asked a different question and their answer is decided above.
  if not v_team and v_vendor is null and not v_is_driver then
    select u.user_company into v_company
      from qvm_new_apps.user_data u where u.user_id = v_uid;
  end if;

  if not (v_team or v_vendor is not null or v_is_driver or v_company is not null) then
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
             -- A customer's shipments are the ones carrying their own orders — reached the
             -- same way the invoices screen reaches them, so the two screens cannot come to
             -- different conclusions about who a company's orders belong to.
             or (v_company is not null and exists (
                   select 1
                     from qvm_new_apps.confirmed_orders co
                     join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
                     join qvm_new_apps.user_data su on su.user_id = q.service_advisor
                    where co.confirmed_order_id = s.confirmed_order_id
                      and su.user_company = v_company))
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
    'role', case when v_team then 'team'
                 when v_vendor is not null then 'vendor'
                 when v_is_driver then 'driver'
                 else 'customer' end));
end
$function$;

-- The same reader must be able to open the row they can now see. Patched rather than rewritten
-- because the rest of this function is long and untouched, and retyping it is how a body picks
-- up a change nobody asked for.
do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.shipment_track(bigint,integer,text)'::regprocedure);
  v_decl_old text := '  v_is_driver boolean;
  v_id bigint := p_shipment_id;';
  v_decl_new text := '  v_is_driver boolean;
  v_company integer;
  v_id bigint := p_shipment_id;';
  v_gate_old text := '          or v_ship.driver_id = v_uid) then';
  v_gate_new text := '          or v_ship.driver_id = v_uid
          or (v_company is not null and exists (
                select 1
                  from qvm_new_apps.confirmed_orders co
                  join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
                  join qvm_new_apps.user_data su on su.user_id = q.service_advisor
                 where co.confirmed_order_id = v_ship.confirmed_order_id
                   and su.user_company = v_company))) then';
  v_set_old text := '  if v_is_driver then
    v_team := false;
    v_vendor := null;
  end if;';
  v_set_new text := '  if v_is_driver then
    v_team := false;
    v_vendor := null;
  end if;

  if not v_team and v_vendor is null and not v_is_driver then
    select u.user_company into v_company
      from qvm_new_apps.user_data u where u.user_id = v_uid;
  end if;';
begin
  -- The sync replays this file, so it has to survive being run twice.
  if position('su.user_company = v_company' in v_def) > 0 then return; end if;

  if position(v_decl_old in v_def) = 0 then raise exception 'declare block not matched'; end if;
  if position(v_gate_old in v_def) = 0 then raise exception 'visibility gate not matched'; end if;
  if position(v_set_old  in v_def) = 0 then raise exception 'driver block not matched'; end if;

  v_def := replace(v_def, v_decl_old, v_decl_new);
  v_def := replace(v_def, v_set_old,  v_set_new);
  v_def := replace(v_def, v_gate_old, v_gate_new);
  execute v_def;
end
$mig$;
