-- A shipment is booked within the company's orders.
--
-- The create-shipment form listed every supplier the company is linked to, then that supplier's
-- not-received purchase orders from every company, and offered the company's addresses as a
-- flat list. Now the form is read from the orders themselves, within the asking user's company:
--
--   * `shipment_scope_company`: the company whose data a user may read — the Qparts Admin reads
--     the company asked for (none = all), anyone else their own.
--   * `purchase_order_client_branch`: the client branch a purchase order is for (its first line's),
--     with the company that branch belongs to.
--   * `shipment_pickup_sources(p_search, p_vendor, p_company_id, p_branch)`: `vendors` are only
--     the suppliers holding not-received orders in scope; with a vendor, `branches` are the client
--     branches those orders are for, and `orders` the orders — for one branch when `p_branch` is
--     given. The old two- and three-argument forms are dropped so the call resolves to one function.
--   * `shipment_dropoff_addresses(p_company_id, p_branch)`: the addresses of one client branch
--     when asked, the company's otherwise — in scope either way.
--   * `shipment_create` refuses an order or a drop-off address outside the user's company.

CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_scope_company(p_company_id integer DEFAULT NULL)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- The Qparts Admin reads what they ask for, or everything. Everyone else reads their own company;
  -- a team member with no company of their own keeps reading what they asked for, as before.
  select case
           when qvm_new_apps.is_qparts_admin() then p_company_id
           else coalesce((select ud.user_company from qvm_new_apps.user_data ud
                           where ud.user_id = auth.uid() and ud.deleted_at is null limit 1),
                         p_company_id)
         end;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.purchase_order_client_branch(p_purchase_order_id bigint)
 RETURNS TABLE(customer_id integer, company_id integer, name text, city text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  -- The branch of the order's first line. An order is raised for one branch; the first line is
  -- how every dashboard reads it.
  select cb.customer_id, cb.company_id, cb.name, cb.city
    from qvm_new_apps.purchase_items pi
    join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
    join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    join qvm_new_apps.v_client_branches cb on cb.customer_id = qi.customer_id
   where pi.purchase_order_id = p_purchase_order_id
   order by pi.purchase_item_id
   limit 1;
$function$;

DROP FUNCTION IF EXISTS qvm_new_apps.shipment_pickup_sources(text, integer);
DROP FUNCTION IF EXISTS qvm_new_apps.shipment_pickup_sources(text, integer, integer);
CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_pickup_sources(
  p_search text DEFAULT NULL,
  p_vendor integer DEFAULT NULL,
  p_company_id integer DEFAULT NULL,
  p_branch integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_co     integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  v_co := qvm_new_apps.shipment_scope_company(p_company_id);

  return (
    with owed as (
      -- Every not-received line still to be collected, with the order's vendor and the client
      -- branch it is for — within the company the asking user may read.
      select w.purchase_item_id, w.purchase_order_id, w.vendor_id,
             b.customer_id as client_branch_id, b.company_id, b.name as client_branch, b.city as client_city
        from qvm_new_apps.v_purchase_items_awaiting_pickup w
        cross join lateral qvm_new_apps.purchase_order_client_branch(w.purchase_order_id) b
       where (v_co is null or b.company_id = v_co)
    )
    select jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'company_id', v_co,

      -- Only the suppliers holding something: a van is booked to collect what is owed.
      'vendors', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'vendor_id',   s.vendor_id,
                 'kind',        'vendor',
                 'vendor_name', s.vendor_name,
                 'orders',      s.orders,
                 'items',       s.items)
               order by s.items desc, s.vendor_name)
          from (
            select o.vendor_id, v.vendor_name,
                   count(distinct o.purchase_order_id) as orders, count(*) as items
              from owed o
              join qvm_new_apps.vendors v on v.vendor_id = o.vendor_id
             where (v_search is null or v.vendor_name ilike '%' || v_search || '%')
             group by o.vendor_id, v.vendor_name
          ) s), '[]'::jsonb),

      -- With a vendor: the client branches its outstanding orders are for.
      'branches', case when p_vendor is null then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object(
                 'client_branch_id', s.client_branch_id,
                 'name',             s.client_branch,
                 'city',             s.client_city,
                 'company_id',       s.company_id,
                 'company',          co.name,
                 'orders',           s.orders,
                 'items',            s.items)
               order by s.items desc, s.client_branch)
          from (
            select o.client_branch_id, o.client_branch, o.client_city, o.company_id,
                   count(distinct o.purchase_order_id) as orders, count(*) as items
              from owed o
             where o.vendor_id = p_vendor
             group by o.client_branch_id, o.client_branch, o.client_city, o.company_id
          ) s
          left join qvm_new_apps.v_client_companies co on co.company_id = s.company_id
        ), '[]'::jsonb) end,

      -- With a vendor: its outstanding orders, for one branch when one was chosen.
      'orders', case when p_vendor is null then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object(
                 'purchase_order_id', po.purchase_order_id,
                 'order_id', po.confirmed_order_id,
                 'invoice_number', po.vendor_invoice_number,
                 'date', po.created_at,
                 'branch_id', po.vendor_branch_id,
                 'branch', vb.branch_name,
                 'city', vb.city,
                 'client_branch_id', g.client_branch_id,
                 'client_branch', g.client_branch,
                 'items', g.n,
                 -- Where this order was asked to go, when the quotation named an address.
                 'dropoff_address_id', d.customer_address_id,
                 'dropoff_label', coalesce(a.label, a.address_line),
                 'dropoff_branch', cb.name)
               order by po.purchase_order_id desc)
          from (
            select o.purchase_order_id, o.client_branch_id, o.client_branch, count(*) as n
              from owed o
             where o.vendor_id = p_vendor
               and (p_branch is null or o.client_branch_id = p_branch)
             group by o.purchase_order_id, o.client_branch_id, o.client_branch
          ) g
          join qvm_new_apps.purchase_orders po on po.purchase_order_id = g.purchase_order_id
          left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = po.vendor_branch_id
          left join qvm_new_apps.v_purchase_order_destination d on d.purchase_order_id = po.purchase_order_id
          left join qvm_new_apps.customer_addresses a on a.address_id = d.customer_address_id
          left join qvm_new_apps.v_client_branches cb on cb.customer_id = a.client_branch_id
        ), '[]'::jsonb) end
    ))
  );
end
$function$;

DROP FUNCTION IF EXISTS qvm_new_apps.shipment_dropoff_addresses(integer);
CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_dropoff_addresses(
  p_company_id integer DEFAULT NULL,
  p_branch integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_co integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  v_co := qvm_new_apps.shipment_scope_company(p_company_id);

  return jsonb_build_object('status', true, 'message', 'ok', 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
             'address_id', a.address_id,
             'label', a.label,
             'address_line', a.address_line,
             'city', a.city,
             'contact_name', a.contact_name,
             'contact_phone', a.contact_phone,
             'branch', b.name,
             'client_branch_id', b.customer_id,
             'workshop', w.name,
             -- A courier needs a point. Said here so the form can mark the ones it cannot use.
             'has_point', a.geo_lat is not null and a.geo_lng is not null,
             'is_default', a.is_default)
           -- The default first, then the ones that take shipments, then located ones, then the rest.
           order by a.is_default desc,
                    coalesce(a.receives_shipments, true) desc,
                    (a.geo_lat is not null) desc,
                    coalesce(a.label, a.address_line))
      from qvm_new_apps.customer_addresses a
      join qvm_new_apps.v_client_branches b on b.customer_id = a.client_branch_id
      left join qvm_new_apps.v_client_workshops w on w.workshop_id = b.workshop_id
     where a.is_active
       and (v_co is null or b.company_id = v_co)
       and (p_branch is null or b.customer_id = p_branch)
  ), '[]'::jsonb));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_create(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_delivery integer := nullif(p_data->>'delivery_id','')::integer;
  v_pickup   bigint  := nullif(p_data->>'pickup_id','')::bigint;
  v_carrier  integer := nullif(p_data->>'carrier_id','')::integer;
  v_type     integer := nullif(p_data->>'ship_type_id','')::integer;
  v_addr     integer := nullif(p_data->>'dropoff_address_id','')::integer;
  v_orders bigint[];
  v_vendors integer; v_vendor integer; v_branches integer;
  v_id bigint; v_code text; v_order integer; v_branch bigint; v_n integer;
  v_enabled boolean;
  -- Whose orders this user may book: their company's, or everyone's for the Qparts Admin.
  v_scope integer := qvm_new_apps.shipment_scope_company(null);
begin
  if not v_team then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- The drop-off must be a branch address of the same company. Checked before the orders so a
  -- wrong address refuses before anything is written.
  if v_addr is not null and v_scope is not null and not exists (
       select 1 from qvm_new_apps.customer_addresses a
       join qvm_new_apps.v_client_branches b on b.customer_id = a.client_branch_id
      where a.address_id = v_addr and b.company_id = v_scope) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- The client coerces every field to a string before sending, so the same list arrives as a
  -- JSON array from one caller and as «13526,13530» from another. Both are read here rather
  -- than making the two callers agree about something neither of them can see.
  if jsonb_typeof(p_data->'purchase_order_ids') = 'array' then
    select array_agg(x::bigint) into v_orders
      from jsonb_array_elements_text(p_data->'purchase_order_ids') x
     where btrim(x) <> '';
  elsif nullif(btrim(coalesce(p_data->>'purchase_order_ids','')), '') is not null then
    select array_agg(btrim(x)::bigint) into v_orders
      from unnest(string_to_array(p_data->>'purchase_order_ids', ',')) x
     where btrim(x) <> '';
  end if;

  if num_nonnulls(v_delivery, v_pickup, v_orders) <> 1 then
    return jsonb_build_object('status', false,
      'message', 'اختر إشعار تسليم أو أوامر شراء للاستلام — واحد منهما فقط', 'data', null);
  end if;

  -- A carrier switched off in settings is not an option. Checked here and not only in the
  -- dropdown, because the dropdown is the client's copy of the answer.
  if v_carrier is not null then
    select is_enabled into v_enabled from qvm_new_apps.shipping_settings where carrier_id = v_carrier;
    if not coalesce(v_enabled, false) then
      return jsonb_build_object('status', false,
        'message', 'شركة الشحن هذه غير مُفعَّلة في الإعدادات', 'data', null);
    end if;
  end if;

  -- Building the pickup from the chosen orders.
  if v_orders is not null then
    -- One van goes to one vendor. Two vendors in a selection is a mistake the form should not
    -- have allowed, and silently creating one shipment for both would send it to one address.
    select count(distinct po.vendor_id), min(po.vendor_id),
           count(distinct po.vendor_branch_id), min(po.vendor_branch_id),
           min(po.confirmed_order_id)
      into v_vendors, v_vendor, v_branches, v_branch, v_order
      from qvm_new_apps.purchase_orders po
     where po.purchase_order_id = any(v_orders);

    if coalesce(v_vendors, 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'أوامر الشراء المختارة غير موجودة', 'data', null);
    end if;
    if v_vendors > 1 then
      return jsonb_build_object('status', false,
        'message', 'كل الأوامر في الشحنة الواحدة لازم تكون لنفس المورد', 'data', null);
    end if;
    -- Every order must be the company's own. A company's user never books another company's
    -- collection, however the ids reached the form.
    if v_scope is not null and exists (
         select 1 from unnest(v_orders) o
         cross join lateral qvm_new_apps.purchase_order_client_branch(o) b
        where b.company_id is distinct from v_scope) then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    -- More than one branch means more than one address to collect from. The shipment keeps no
    -- branch rather than claiming a wrong one, and the address field is then filled by hand.
    if coalesce(v_branches, 0) > 1 then v_branch := null; end if;

    -- Asked before anything is written. A `return` inside this function does not roll the
    -- statement back, so refusing after creating the pickup would leave an empty one behind
    -- for every rejected attempt.
    if not exists (
      -- The same view the picker lists from. Two spellings of this rule is what had the
      -- button refusing orders the list had just offered.
      select 1 from qvm_new_apps.v_purchase_items_awaiting_pickup w
       where w.purchase_order_id = any(v_orders)) then
      return jsonb_build_object('status', false,
        'message', 'مفيش أصناف غير مستلمة في الأوامر المختارة', 'data', null);
    end if;

    insert into qvm_new_apps.pickups (purchase_order_id, pickup_date)
    values (v_orders[1], now())
    returning pickup_id into v_pickup;

    insert into qvm_new_apps.pickup_orders (pickup_id, purchase_order_id)
    select v_pickup, x from unnest(v_orders) x;

    -- Only the items still owed, and only the quantity still owed. An item already on another
    -- pickup is excluded so two vans are never sent for the same part.
    insert into qvm_new_apps.pickup_items (pickup_id, purchase_item_id, pickup_qty, created_by)
    select v_pickup, w.purchase_item_id, w.qty_owed, auth.uid()
      from qvm_new_apps.v_purchase_items_awaiting_pickup w
     where w.purchase_order_id = any(v_orders);
  end if;

  -- One shipment per delivery or pickup. A second one would split the items and leave the
  -- board showing the same parts twice on two different vans.
  if exists (select 1 from qvm_new_apps.shipments s
              where (v_delivery is not null and s.delivery_id = v_delivery)
                 or (v_pickup is not null and s.pickup_id = v_pickup)) then
    return jsonb_build_object('status', false,
      'message', 'توجد شحنة بالفعل لهذا الإشعار — افتحها من اللوحة', 'data', null);
  end if;

  if v_delivery is not null then
    select d.confirmed_order_id into v_order
      from qvm_new_apps.deliveries d where d.delivery_id = v_delivery;
  elsif v_orders is null then
    select po.confirmed_order_id, po.vendor_branch_id into v_order, v_branch
      from qvm_new_apps.pickups pk
      join qvm_new_apps.purchase_orders po on po.purchase_order_id = pk.purchase_order_id
     where pk.pickup_id = v_pickup;
  end if;

  insert into qvm_new_apps.shipments (
    shipment_code, delivery_id, pickup_id, confirmed_order_id,
    carrier_id, shipment_type_id,
    pickup_vendor_branch_id, pickup_address, pickup_phone,
    dropoff_address_id, dropoff_address, dropoff_contact, dropoff_phone,
    price, cost, notes, status_id, created_by)
  values (
    -- Placeholder; replaced below with a code built from this row's own id, so the two
    -- can never drift apart the way a second sequence would let them.
    'SHP-PENDING-' || gen_random_uuid()::text,
    v_delivery, v_pickup, v_order,
    v_carrier, v_type,
    coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch),
    -- The branch's own address and phone, when the form did not type one: a pickup with no
    -- address is a driver phoning the office to ask where he is going.
    coalesce(nullif(btrim(coalesce(p_data->>'pickup_address','')), ''),
             (select vb.address || case when vb.city is not null then ' — ' || vb.city else '' end
                from qvm_new_apps.vendor_branches vb
               where vb.vendor_branch_id = coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch))),
    coalesce(nullif(btrim(coalesce(p_data->>'pickup_phone','')), ''),
             (select vb.phone from qvm_new_apps.vendor_branches vb
               where vb.vendor_branch_id = coalesce(nullif(p_data->>'pickup_vendor_branch_id','')::bigint, v_branch))),
    v_addr,
    -- The address text is copied, not only referenced: a shipment has to still read
    -- correctly after somebody edits or retires the address record it came from.
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_address','')), ''),
             (select a.address_line || case when a.city is not null then ' — ' || a.city else '' end
                from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_contact','')), ''),
             (select a.contact_name from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    coalesce(nullif(btrim(coalesce(p_data->>'dropoff_phone','')), ''),
             (select a.contact_phone from qvm_new_apps.customer_addresses a where a.address_id = v_addr)),
    nullif(btrim(coalesce(p_data->>'price','')), '')::numeric,
    nullif(btrim(coalesce(p_data->>'cost','')), '')::numeric,
    nullif(btrim(coalesce(p_data->>'notes','')), ''),
    qvm_new_apps.shipment_status_id('Ready to Dispatch'),
    auth.uid())
  returning shipment_id into v_id;

  v_code := 'SHP-' || to_char(now(), 'YYMM') || '-' || lpad(v_id::text, 5, '0');
  update qvm_new_apps.shipments set shipment_code = v_code where shipment_id = v_id;

  -- The contents come from the note itself rather than being chosen again: the quantities
  -- were already agreed there, and asking twice is how the two end up disagreeing.
  if v_delivery is not null then
    insert into qvm_new_apps.shipment_items (shipment_id, delivery_item_id, qty)
    select v_id, di.delivery_item_id, di.delivered_qty
      from qvm_new_apps.delivery_items di where di.delivery_id = v_delivery;
  else
    insert into qvm_new_apps.shipment_items (shipment_id, pickup_item_id, qty)
    select v_id, pi.pickup_item_id, pi.pickup_qty
      from qvm_new_apps.pickup_items pi where pi.pickup_id = v_pickup;
  end if;
  get diagnostics v_n = row_count;

  insert into qvm_new_apps.status_logs (shipment_id, item_status, status_changed_by, created_by)
  values (v_id, qvm_new_apps.shipment_status_id('Ready to Dispatch'), auth.uid(), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('shipment_id', v_id, 'code', v_code, 'items', v_n));
end
$function$;
