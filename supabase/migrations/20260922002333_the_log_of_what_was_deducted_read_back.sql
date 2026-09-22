-- The log of what was deducted, read back.
--
-- Scoped by the same rules as the marketplace itself: an owner sees its own company's and nobody
-- else's, an operator sees whichever company it has open. A log that leaks across companies is a
-- worse feature than no log.
create or replace function qvm_new_apps.integration_activity(
  p_company_id integer default null,
  p_service    text    default null,
  p_limit      integer default 50,
  p_offset     integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op     boolean := qvm_new_apps.wallet_is_operator();
  v_co     integer := p_company_id;
  v_wallet bigint;
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows   jsonb;
  v_total  integer;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
    if v_co is null then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
  end if;

  if v_co is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data',
      jsonb_build_object('rows', '[]'::jsonb, 'total', 0));
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if v_wallet is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data',
      jsonb_build_object('rows', '[]'::jsonb, 'total', 0));
  end if;

  select count(*) into v_total
    from qvm_new_apps.integration_events e
    join qvm_new_apps.wallet_subscriptions s using (subscription_id)
   where s.wallet_id = v_wallet
     and (p_service is null or e.service_key = p_service);

  select coalesce(jsonb_agg(r order by r_created_at desc, r_event_id desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'event_id', e.event_id,
               'service_key', e.service_key,
               'service_name_ar', sv.name_ar,
               'service_name_en', sv.name_en,
               'metric', e.metric,
               'amount', e.amount,
               'scope', nullif(e.scope, ''),
               'kind', e.kind,
               'ref', e.ref,
               'created_at', e.created_at,
               'plan_name', s.plan_name,
               -- Who. Falls back to the email, then to «—»: a log that hides the actor because
               -- the display name was never filled in is worse than one that shows an address.
               'actor', case when e.user_id is null then null
                             else coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''),
                                           u.email) end) as r,
             e.created_at as r_created_at,
             e.event_id   as r_event_id
        from qvm_new_apps.integration_events e
        join qvm_new_apps.wallet_subscriptions s using (subscription_id)
        left join qvm_new_apps.integration_services sv on sv.service_key = e.service_key
        left join auth.users u on u.id = e.user_id
       where s.wallet_id = v_wallet
         and (p_service is null or e.service_key = p_service)
       order by e.created_at desc, e.event_id desc
       limit v_limit offset greatest(coalesce(p_offset, 0), 0)) q;

  return jsonb_build_object('status', true, 'message', 'ok', 'data',
    jsonb_build_object('rows', v_rows, 'total', v_total));
end
$$;

grant execute on function qvm_new_apps.integration_activity(integer, text, integer, integer)
  to authenticated, service_role;
