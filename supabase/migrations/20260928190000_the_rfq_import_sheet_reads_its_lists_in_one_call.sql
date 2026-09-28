-- The RFQ import sheet reads its lists in one call.
--
-- The import page used to compose its sheet from the form's own RPCs one at a time: the context,
-- then a call per client for its branches, a call per branch for its addresses and another for
-- its customers, and a call per car brand for its models — several hundred requests for a
-- platform-wide sheet. This function answers all of it at once, scoped exactly as those RPCs
-- scope it: a person whose reach is narrowed (a Company Admin included) gets their workshops'
-- companies and branches from get_quotation_context; an unrestricted internal user gets every
-- client that can number an order, as get_clients does.

set search_path to qvm_new_apps, public;

create or replace function qvm_new_apps.rfq_import_options()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_ctx jsonb;
  v_scoped boolean;
  v_companies jsonb;
  v_branches jsonb;
  v_branch_ids integer[];
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_ctx := qvm_new_apps.get_quotation_context();
  v_scoped := not coalesce((v_ctx->'data'->>'unrestricted')::boolean, false)
              and jsonb_array_length(coalesce(v_ctx->'data'->'workshops', '[]'::jsonb)) > 0;

  if v_scoped then
    select coalesce(jsonb_agg(jsonb_build_object('company_id', x.company_id, 'name', x.name) order by x.name), '[]'::jsonb)
      into v_companies
      from (select distinct (c->>'company_id')::int as company_id, c->>'name' as name
              from jsonb_array_elements(v_ctx->'data'->'workshops') w,
                   jsonb_array_elements(w->'companies') c) x;
    -- A workshop serves several companies and holds the branches: one row per (company, branch).
    select coalesce(jsonb_agg(jsonb_build_object(
             'customer_id', (b->>'customer_id')::int, 'name', b->>'name',
             'company_id', (c->>'company_id')::int, 'company_name', c->>'name',
             'workshop_id', (w->>'workshop_id')::bigint,
             'ready', coalesce((b->'readiness'->>'ready')::boolean, true))
             order by c->>'name', b->>'name'), '[]'::jsonb)
      into v_branches
      from jsonb_array_elements(v_ctx->'data'->'workshops') w,
           jsonb_array_elements(w->'companies') c,
           jsonb_array_elements(w->'branches') b;
  else
    select coalesce(jsonb_agg(jsonb_build_object('company_id', x.company_id, 'name', x.name) order by x.name), '[]'::jsonb)
      into v_companies
      from (select ld.list_data_id as company_id, coalesce(vc.name, ld.list_data) as name
              from qvm_new_apps.list_data ld
              join qvm_new_apps.lists l on l.list_id = ld.list_id
              left join qvm_new_apps.v_client_companies vc on vc.company_id = ld.list_data_id
             where l.list_name = 'client_name'
               and exists (select 1 from qvm_new_apps.order_number_sequences ons
                            where ons.lists_data_id = ld.list_data_id)) x;
    select coalesce(jsonb_agg(jsonb_build_object(
             'customer_id', cb.customer_id, 'name', vb.name,
             'company_id', cb.list_data_id, 'company_name', comp.name,
             'workshop_id', cb.workshop_id, 'ready', true)
             order by comp.name, vb.name), '[]'::jsonb)
      into v_branches
      from qvm_new_apps.client_branches cb
      join qvm_new_apps.v_client_branches vb on vb.customer_id = cb.customer_id
      join (select (c->>'company_id')::int as company_id, c->>'name' as name
              from jsonb_array_elements(v_companies) c) comp on comp.company_id = cb.list_data_id;
  end if;

  select coalesce(array_agg(distinct (b->>'customer_id')::int), '{}'::integer[])
    into v_branch_ids
    from jsonb_array_elements(v_branches) b;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'scoped', v_scoped,
    'companies', v_companies,
    'branches', v_branches,
    -- The same rows branch_order_addresses gives, for every branch at once.
    'addresses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'address_id', a.address_id, 'branch_id', a.client_branch_id,
               'label', a.label, 'address_line', a.address_line,
               'city', coalesce(vc.name, a.city), 'district', vd.name, 'is_default', a.is_default)
               order by a.client_branch_id, a.is_default desc, a.address_id)
        from qvm_new_apps.customer_addresses a
        left join qvm_new_apps.v_cities vc on vc.city_id = a.city_id
        left join qvm_new_apps.v_districts vd on vd.district_id = a.district_id
       where a.client_branch_id = any(v_branch_ids) and a.is_active and a.receives_orders), '[]'::jsonb),
    -- The same rows list_end_customers_for_order gives per workshop, keyed to the branches it holds.
    'customers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'end_customer_id', x.end_customer_id, 'name', x.name,
               'customer_code', x.customer_code, 'branch_ids', to_jsonb(x.branch_ids))
               order by x.name)
        from (select v.end_customer_id, v.name, v.customer_code,
                     array_agg(distinct cb.customer_id) as branch_ids
                from qvm_new_apps.end_customer_owners o
                join qvm_new_apps.v_end_customers v on v.end_customer_id = o.end_customer_id
                join qvm_new_apps.client_branches cb
                  on cb.workshop_id = o.workshop_id and cb.customer_id = any(v_branch_ids)
               where v.is_active
               group by v.end_customer_id, v.name, v.customer_code) x), '[]'::jsonb),
    'brands', coalesce((
      select jsonb_agg(jsonb_build_object('brand_id', ld.list_data_id, 'name', ld.list_data) order by ld.list_data)
        from qvm_new_apps.list_data ld join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'car_brand'), '[]'::jsonb),
    'models', coalesce((
      select jsonb_agg(jsonb_build_object('brand_id', m.brand_id, 'brand_name', ld.list_data, 'name', m.name_en)
                       order by ld.list_data, (lower(m.name_en) = 'other'), m.name_en)
        from qvm_new_apps.vehicle_models m
        join qvm_new_apps.list_data ld on ld.list_data_id = m.brand_id
       where m.is_active), '[]'::jsonb),
    'brand_classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'name', ld.list_data) order by ld.list_data)
        from qvm_new_apps.list_data ld join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'brand_class'), '[]'::jsonb),
    'order_types', coalesce((
      select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'name', ld.list_data) order by ld.list_data)
        from qvm_new_apps.list_data ld join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'order_type'), '[]'::jsonb),
    'delivery_types', coalesce((
      select jsonb_agg(jsonb_build_object('id', ld.list_data_id, 'name', ld.list_data) order by ld.list_data)
        from qvm_new_apps.list_data ld join qvm_new_apps.lists l on l.list_id = ld.list_id
       where l.list_name = 'delivery_type'), '[]'::jsonb)
  ));
end $function$;

create or replace function public.rfq_import_options()
 returns jsonb
 language sql
 stable security definer
as $function$
  select qvm_new_apps.rfq_import_options();
$function$;
