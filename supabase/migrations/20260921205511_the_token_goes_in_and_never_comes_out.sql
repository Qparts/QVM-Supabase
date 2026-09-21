-- Saving a carrier account. The token goes in and never comes out.
--
-- It returns the hint and the webhook URL, not the key. There is no companion «reveal» function
-- and there should not be one: the moment a key can be fetched by a browser it has left the
-- server, and every later argument about whether the UI hides it well enough is beside the point.
--
-- Passing null for the token means «leave the one that is there» — so a company can flip between
-- sandbox and production, or rename their base URL, without re-typing a secret they may not have
-- to hand.
create or replace function qvm_new_apps.carrier_connection_save(
  p_carrier_key   text,
  p_api_token     text default null,
  p_environment   text default 'production',
  p_api_base_url  text default null,
  p_company_id    integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op      boolean := qvm_new_apps.wallet_is_operator();
  v_co      integer := p_company_id;
  v_carrier integer;
  v_wallet  bigint;
  v_secret  text;
  v_id      bigint;
  v_existing text;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, true);
  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'ربط الناقل من صلاحية مالك الحساب');
  end if;

  if p_environment not in ('sandbox','production') then
    return jsonb_build_object('status', false, 'message', 'بيئة غير معروفة', 'data', null);
  end if;

  select list_data_id into v_carrier from qvm_new_apps.list_data
   where lower(list_data) = lower(p_carrier_key) limit 1;
  if v_carrier is null then
    return jsonb_build_object('status', false, 'message', 'الناقل غير معروف', 'data', null);
  end if;

  select api_token, webhook_secret into v_existing, v_secret
    from qvm_new_apps.carrier_credentials
   where carrier_id = v_carrier and company_id = v_co and environment = p_environment;

  if coalesce(nullif(btrim(coalesce(p_api_token, '')), ''), v_existing) is null then
    return jsonb_build_object('status', false, 'message', 'أدخل رمز API', 'data', null);
  end if;

  -- One secret per company per carrier, minted once and kept. Rotating it silently would break
  -- the webhook the carrier already has registered on their side.
  v_secret := coalesce(v_secret, replace(gen_random_uuid()::text, '-', ''));

  insert into qvm_new_apps.carrier_credentials
    (carrier_id, company_id, environment, api_token, api_base_url, webhook_secret,
     is_active, updated_by, updated_at)
  values (v_carrier, v_co, p_environment,
          coalesce(nullif(btrim(coalesce(p_api_token,'')), ''), v_existing),
          p_api_base_url, v_secret, true, auth.uid(), now())
  on conflict (carrier_id, company_id, environment) where company_id is not null
  do update set api_token    = coalesce(nullif(btrim(coalesce(excluded.api_token,'')), ''),
                                        qvm_new_apps.carrier_credentials.api_token),
                api_base_url = coalesce(excluded.api_base_url, qvm_new_apps.carrier_credentials.api_base_url),
                is_active    = true,
                updated_by   = excluded.updated_by,
                updated_at   = now()
  returning credential_id into v_id;

  -- Only one environment can be live at a time. A shipment created in sandbox and then tracked
  -- against production is the failure this prevents, and it is the reason the carrier function
  -- reads `is_active` rather than picking a row by name.
  update qvm_new_apps.carrier_credentials
     set is_active = false
   where carrier_id = v_carrier and company_id = v_co and credential_id <> v_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'credential_id', v_id, 'environment', p_environment,
    'webhook_url', 'https://exizrhlkxoqljiypzwyx.supabase.co/functions/v1/'
                   || lower(p_carrier_key) || '?s=' || v_secret));
end
$$;

-- Disconnecting deactivates rather than deletes. The shipments already created against this
-- account still need their credential to be tracked and reconciled; deleting it would orphan
-- them, and a carrier that cannot be asked «what happened to shipment 41» is worse than one that
-- is merely switched off.
create or replace function qvm_new_apps.carrier_connection_disable(
  p_carrier_key text,
  p_company_id  integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op boolean := qvm_new_apps.wallet_is_operator();
  v_co integer := p_company_id;
  v_carrier integer;
  v_wallet bigint;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select list_data_id into v_carrier from qvm_new_apps.list_data
   where lower(list_data) = lower(p_carrier_key) limit 1;

  update qvm_new_apps.carrier_credentials
     set is_active = false, updated_by = auth.uid(), updated_at = now()
   where carrier_id = v_carrier and company_id = v_co;

  -- And every branch stops offering it, so nobody dispatches against a connection that is off.
  update qvm_new_apps.carrier_branch_settings
     set enabled = false, updated_by = auth.uid(), updated_at = now()
   where carrier_id = v_carrier and company_id = v_co and enabled;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$$;

create or replace function qvm_new_apps.carrier_branch_set(
  p_carrier_key text,
  p_branch_id   integer,
  p_enabled     boolean,
  p_pickup_note text default null,
  p_company_id  integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op boolean := qvm_new_apps.wallet_is_operator();
  v_co integer := p_company_id;
  v_carrier integer;
  v_wallet bigint;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if not qvm_new_apps.wallet_can_manage(v_wallet) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select list_data_id into v_carrier from qvm_new_apps.list_data
   where lower(list_data) = lower(p_carrier_key) limit 1;

  -- A branch cannot be switched on while the connection is off. Otherwise a dispatcher is shown a
  -- carrier that will fail at the moment it matters, which is worse than not being shown it.
  if p_enabled and not exists (
       select 1 from qvm_new_apps.carrier_credentials
        where carrier_id = v_carrier and company_id = v_co and is_active) then
    return jsonb_build_object('status', false, 'data', null,
      'message', 'فعّل الاتصال بالناقل أولاً');
  end if;

  -- The branch must be one of this company's. Checked rather than trusted: the id arrives in the
  -- request body.
  if not exists (
       select 1 from qvm_new_apps.client_branches b
        join qvm_new_apps.client_workshops w on w.workshop_id = b.workshop_id
       where b.list_data_id = p_branch_id and w.company_id = v_co) then
    return jsonb_build_object('status', false, 'message', 'الفرع غير تابع لهذه الشركة', 'data', null);
  end if;

  insert into qvm_new_apps.carrier_branch_settings
    (company_id, carrier_id, branch_id, enabled, pickup_note, updated_by)
  values (v_co, v_carrier, p_branch_id, p_enabled, p_pickup_note, auth.uid())
  on conflict (company_id, carrier_id, branch_id)
  do update set enabled = excluded.enabled,
                pickup_note = coalesce(excluded.pickup_note, qvm_new_apps.carrier_branch_settings.pickup_note),
                updated_by = excluded.updated_by, updated_at = now();

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('branch_id', p_branch_id, 'enabled', p_enabled));
end
$$;

revoke all on function qvm_new_apps.carrier_connection_save(text, text, text, text, integer) from public;
revoke all on function qvm_new_apps.carrier_connection_disable(text, integer) from public;
revoke all on function qvm_new_apps.carrier_branch_set(text, integer, boolean, text, integer) from public;
grant execute on function qvm_new_apps.carrier_connection_save(text, text, text, text, integer),
                          qvm_new_apps.carrier_connection_disable(text, integer),
                          qvm_new_apps.carrier_branch_set(text, integer, boolean, text, integer)
  to authenticated, service_role;
