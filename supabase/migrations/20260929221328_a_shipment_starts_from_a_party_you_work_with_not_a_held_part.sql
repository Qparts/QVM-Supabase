-- The shipment picker asked the wrong question.
--
-- It listed «vendors holding a purchase item whose receipt_status is exactly not_received and
-- which is not already in a pickup». Two things follow from that, and both were on screen:
--
--   * It said «No vendor is holding parts marked not received» — true, and useless. All five such
--     items were already in a pickup, so the correct answer to its question was an empty list.
--   * 72 items carry receipt_status NULL — nobody has marked them either way — across 4 vendors.
--     Un-received in every practical sense, and invisible to `= 'not_received'`.
--
-- The question a dispatcher actually asks is «who do we work with», and then «what of theirs is
-- still with them». So the parties come from company_parties() — the same list the wallet and the
-- AI page read — and the counts are attached to each rather than deciding who appears.
--
-- Unclaimed now means «not received yet»: not_received, or nobody has said. A part somebody has
-- confirmed as received is the only one that is definitely not waiting to be collected.

create or replace function qvm_new_apps.shipment_pickup_sources(
  p_search text default null,
  p_vendor integer default null,
  p_company_id integer default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = qvm_new_apps, public
as $function$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_co     integer := p_company_id;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Fall back to the caller's own company, so the picker works without the screen having to
  -- know which company it is looking at.
  if v_co is null then
    select ud.user_company into v_co
      from qvm_new_apps.user_data ud
     where ud.user_id = auth.uid() and ud.deleted_at is null
     limit 1;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'company_id', v_co,

    'vendors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vendor_id',   s.vendor_id,
               'workshop_id', s.workshop_id,
               'kind',        s.kind,
               'vendor_name', s.name,
               'orders',      coalesce(s.orders, 0),
               'items',       coalesce(s.items, 0))
             order by (s.kind = 'company') desc, s.name)
        from (
          select cp.kind, cp.vendor_id, cp.workshop_id, cp.name,
                 cnt.orders, cnt.items
            from qvm_new_apps.company_parties(v_co) cp
            -- Counts describe a party; they no longer decide whether it is listed. A supplier you
            -- work with but have nothing outstanding from is still a supplier you can ship from.
            left join lateral (
              select count(distinct pi.purchase_order_id) as orders, count(*) as items
                from qvm_new_apps.purchase_items pi
                join qvm_new_apps.purchase_orders po
                  on po.purchase_order_id = pi.purchase_order_id
               where cp.vendor_id is not null
                 and po.vendor_id = cp.vendor_id
                 and coalesce(pi.receipt_status, 'not_received') <> 'received'
                 and not exists (select 1 from qvm_new_apps.pickup_items pk
                                  where pk.purchase_item_id = pi.purchase_item_id)
            ) cnt on true
           where v_search is null or cp.name ilike '%' || v_search || '%'
        ) s), '[]'::jsonb),

    'orders', case when p_vendor is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'purchase_order_id', po.purchase_order_id,
               'order_id', po.confirmed_order_id,
               'invoice_number', po.vendor_invoice_number,
               'date', po.created_at,
               'branch_id', po.vendor_branch_id,
               'branch', vb.branch_name,
               'city', vb.city,
               'items', cnt.n)
             order by po.purchase_order_id desc)
        from qvm_new_apps.purchase_orders po
        left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = po.vendor_branch_id
        join lateral (
          select count(*) as n
            from qvm_new_apps.purchase_items pi
           where pi.purchase_order_id = po.purchase_order_id
             and coalesce(pi.receipt_status, 'not_received') <> 'received'
             and not exists (select 1 from qvm_new_apps.pickup_items pk
                              where pk.purchase_item_id = pi.purchase_item_id)
        ) cnt on cnt.n > 0
       where po.vendor_id = p_vendor), '[]'::jsonb) end
  ));
end
$function$;
