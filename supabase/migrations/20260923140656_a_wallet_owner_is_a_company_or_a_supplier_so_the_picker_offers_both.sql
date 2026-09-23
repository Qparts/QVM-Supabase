-- A wallet owner is a company or a supplier, so the picker offers both.
--
-- The wallet page's own helper text says «A wallet belongs to one company or one supplier», and
-- the list underneath it was filled from the supplier facet of the documents list — suppliers
-- only, under a label that said «Supplier». So every company wallet on the platform was
-- unreachable from the screen built to open wallets, including the one the balance card was
-- sitting above showing 0.00.
--
-- `wallet_get` already takes both ids. Only the list was half-built.
--
-- Scoped by `wallet_can_manage`, the same rule the wallet itself answers to, so the picker can
-- never offer an owner whose wallet then comes back forbidden — which is the property the old
-- supplier-facet version had by accident and this one has on purpose.
create or replace function qvm_new_apps.wallet_owners()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(r order by kind, name), '[]'::jsonb)
    into v_rows
    from (
      select 'company' as kind,
             c.company_id as id,
             coalesce(nm.name, 'Company ' || c.company_id) as name,
             jsonb_build_object(
               'kind', 'company', 'company_id', c.company_id, 'vendor_id', null,
               'name', coalesce(nm.name, 'Company ' || c.company_id)) as r
        from qvm_new_apps.client_companies c
        left join lateral (
          select d.name from qvm_new_apps.client_companies_descriptions d
           where d.company_id = c.company_id and d.name is not null
           order by d.language_id limit 1) nm on true
       where c.is_active
         -- The wallet may not exist yet; `false` means «do not create one just to list it».
         -- An owner with no wallet is still an owner somebody may want to open.
         and qvm_new_apps.wallet_can_manage(
               coalesce(qvm_new_apps.wallet_of(c.company_id, null, false), -1))

      union all

      select 'vendor',
             v.vendor_id,
             coalesce(v.vendor_name, 'Vendor ' || v.vendor_id),
             jsonb_build_object(
               'kind', 'vendor', 'company_id', null, 'vendor_id', v.vendor_id,
               'name', coalesce(v.vendor_name, 'Vendor ' || v.vendor_id))
        from qvm_new_apps.vendors v
       where qvm_new_apps.wallet_can_manage(
               coalesce(qvm_new_apps.wallet_of(null, v.vendor_id, false), -1))
    ) q;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', v_rows);
end
$$;

grant execute on function qvm_new_apps.wallet_owners() to authenticated, service_role;
