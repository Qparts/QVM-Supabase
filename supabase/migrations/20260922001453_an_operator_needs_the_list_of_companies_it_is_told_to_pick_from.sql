-- An operator needs the list of companies it is told to pick from.
--
-- `integrations_market` already answers «needs_owner» for someone on the Qparts side, because an
-- operator has no company of their own. But nothing ever handed them the companies, so the page
-- said «choose a company» beside no way to choose one — a door with no handle, which is worse than
-- no door: it reads as broken rather than as unfinished.
--
-- Scoped by exactly the same test the marketplace uses. A list that offered a company whose
-- marketplace then came back forbidden would be a worse lie than an empty list.
create or replace function qvm_new_apps.integration_owners()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_rows jsonb;
begin
  if not qvm_new_apps.wallet_is_operator() then
    -- Not an error. An owner has one company and never picks; handing them a list would invite
    -- them to try opening somebody else's.
    return jsonb_build_object('status', true, 'message', 'ok', 'data', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'company_id', c.company_id,
           'name', coalesce(nm.name, 'Company ' || c.company_id))
         order by coalesce(nm.name, '') , c.company_id), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.client_companies c
    -- The name lives one table over, once per language. One row, not one per language —
    -- otherwise every company would appear as many times as it has been translated.
    left join lateral (
      select d.name from qvm_new_apps.client_companies_descriptions d
       where d.company_id = c.company_id and d.name is not null
       order by d.language_id
       limit 1) nm on true
   where c.is_active;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', v_rows);
end
$$;

grant execute on function qvm_new_apps.integration_owners() to authenticated, service_role;
