-- The catalogue has a reader, but nobody can write to it.
--
-- Services, plans, prices, limits and the comparison rows are all data — deliberately, so that
-- «the limit a company bought last month can still be read next year, which a constant in a
-- bundle cannot». Every one of them was seeded by a migration, and changing a price has meant
-- writing another migration ever since.
--
-- That is a catalogue nobody on the business side can touch. These are the writes, guarded by
-- the same test that decides who may move money — `wallet_is_operator()` rather than
-- `is_qparts_team()`, because the latter is true for a Company Admin and a customer editing the
-- price list is not a smaller problem than a customer reading somebody else's wallet.

-- ── The whole catalogue, for the admin screen ──────────────────────────────────────────────────
-- Everything about every service including the inactive ones, which the marketplace read hides.
-- An admin cannot re-enable what they cannot see.
create or replace function qvm_new_apps.admin_integrations_catalogue()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_rows jsonb;
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'هذه الصفحة من صلاحية قبارتس', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'service_key', s.service_key,
    'name_ar', s.name_ar, 'name_en', s.name_en,
    'category', s.category, 'kind', s.kind,
    'tagline_ar', s.tagline_ar, 'tagline_en', s.tagline_en,
    'blurb_ar', s.blurb_ar, 'blurb_en', s.blurb_en,
    'badge', s.badge, 'accent', s.accent, 'logo_url', s.logo_url,
    'is_active', s.is_active, 'sort_order', s.sort_order,
    'metrics', s.metrics,
    'plans', (select coalesce(jsonb_agg(jsonb_build_object(
                'plan_key', p.plan_key, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'price', p.price, 'period', p.period, 'limits', p.limits,
                'is_popular', p.is_popular, 'is_active', p.is_active,
                'sort_order', p.sort_order,
                -- How many companies are on this plan right now. An admin about to change a
                -- price or retire a tier needs to know who it lands on.
                'subscribers', (select count(*) from qvm_new_apps.wallet_subscriptions w
                                 where w.service_key = p.service_key
                                   and w.plan_key = p.plan_key and w.status = 'active'))
                order by p.sort_order, p.plan_key), '[]'::jsonb)
                from qvm_new_apps.integration_plans p
               where p.service_key = s.service_key),
    'subscribers', (select count(*) from qvm_new_apps.wallet_subscriptions w
                     where w.service_key = s.service_key and w.status = 'active'))
    order by s.sort_order, s.service_key), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.integration_services s;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'services', v_rows,
    -- The rates the AI page prices against, edited from the same screen rather than from a
    -- migration — they are business numbers, not schema.
    'rates', (select coalesce(jsonb_agg(jsonb_build_object(
                'rate_key', r.rate_key, 'amount', r.amount,
                'unit', r.unit, 'description', r.description)
                order by r.rate_key), '[]'::jsonb)
                from qvm_new_apps.wallet_rates r)));
end
$$;

-- ── Writing a service ──────────────────────────────────────────────────────────────────────────
-- Upsert on the key: an admin adding «SMSA» and an admin renaming it are the same call, and a
-- separate create/update pair is two places for the validation to differ.
create or replace function qvm_new_apps.admin_integration_service_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_key text := nullif(btrim(p_data ->> 'service_key'), '');
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'هذه الصفحة من صلاحية قبارتس', 'data', null);
  end if;
  if v_key is null then
    return jsonb_build_object('status', false, 'message', 'مفتاح الخدمة مطلوب', 'data', null);
  end if;
  if coalesce(p_data ->> 'kind', '') not in ('plan', 'connect', 'soon') then
    return jsonb_build_object('status', false, 'message', 'نوع الخدمة غير معروف', 'data', null);
  end if;

  insert into qvm_new_apps.integration_services
    (service_key, name_ar, name_en, category, kind, tagline_ar, tagline_en,
     blurb_ar, blurb_en, badge, accent, logo_url, is_active, sort_order, metrics)
  values (v_key,
          p_data ->> 'name_ar', p_data ->> 'name_en',
          p_data ->> 'category', p_data ->> 'kind',
          p_data ->> 'tagline_ar', p_data ->> 'tagline_en',
          p_data ->> 'blurb_ar', p_data ->> 'blurb_en',
          nullif(p_data ->> 'badge', ''), nullif(p_data ->> 'accent', ''),
          nullif(p_data ->> 'logo_url', ''),
          coalesce((p_data ->> 'is_active')::boolean, true),
          coalesce((p_data ->> 'sort_order')::integer, 100),
          coalesce(p_data -> 'metrics', '[]'::jsonb))
  on conflict (service_key) do update set
    name_ar = excluded.name_ar, name_en = excluded.name_en,
    category = excluded.category, kind = excluded.kind,
    tagline_ar = excluded.tagline_ar, tagline_en = excluded.tagline_en,
    blurb_ar = excluded.blurb_ar, blurb_en = excluded.blurb_en,
    badge = excluded.badge, accent = excluded.accent, logo_url = excluded.logo_url,
    is_active = excluded.is_active, sort_order = excluded.sort_order,
    metrics = excluded.metrics;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('service_key', v_key));
end
$$;

-- ── Writing a plan ─────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.admin_integration_plan_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_service text := nullif(btrim(p_data ->> 'service_key'), '');
  v_plan    text := nullif(btrim(p_data ->> 'plan_key'), '');
  v_limits  jsonb := coalesce(p_data -> 'limits', '{}'::jsonb);
  v_price   numeric := (p_data ->> 'price')::numeric;
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'هذه الصفحة من صلاحية قبارتس', 'data', null);
  end if;
  if v_service is null or v_plan is null then
    return jsonb_build_object('status', false, 'message', 'مفتاح الخدمة والباقة مطلوبان', 'data', null);
  end if;
  if not exists (select 1 from qvm_new_apps.integration_services s where s.service_key = v_service) then
    return jsonb_build_object('status', false, 'message', 'الخدمة غير موجودة', 'data', null);
  end if;
  if v_price is null or v_price < 0 then
    return jsonb_build_object('status', false, 'message', 'السعر يجب أن يكون صفرًا أو أكثر', 'data', null);
  end if;
  if jsonb_typeof(v_limits) <> 'object' then
    return jsonb_build_object('status', false, 'message', 'الحدود يجب أن تكون كائنًا', 'data', null);
  end if;

  insert into qvm_new_apps.integration_plans
    (service_key, plan_key, name_ar, name_en, price, period, limits,
     is_popular, is_active, sort_order)
  values (v_service, v_plan,
          p_data ->> 'name_ar', p_data ->> 'name_en',
          v_price,
          coalesce(nullif(p_data ->> 'period', ''), 'monthly'),
          v_limits,
          coalesce((p_data ->> 'is_popular')::boolean, false),
          coalesce((p_data ->> 'is_active')::boolean, true),
          coalesce((p_data ->> 'sort_order')::integer, 100))
  on conflict (service_key, plan_key) do update set
    name_ar = excluded.name_ar, name_en = excluded.name_en,
    price = excluded.price, period = excluded.period, limits = excluded.limits,
    is_popular = excluded.is_popular, is_active = excluded.is_active,
    sort_order = excluded.sort_order;

  -- Only one tier can be «most chosen». Enforced here rather than left to whoever clicks last,
  -- because two highlighted columns is a sheet that recommends nothing.
  if coalesce((p_data ->> 'is_popular')::boolean, false) then
    update qvm_new_apps.integration_plans
       set is_popular = false
     where service_key = v_service and plan_key <> v_plan and is_popular;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'service_key', v_service, 'plan_key', v_plan,
    -- Said back, because changing a price does not change what existing subscribers pay: their
    -- amount was snapshotted when they subscribed. An admin should know that from the screen,
    -- not discover it from a support ticket.
    'active_subscribers', (select count(*) from qvm_new_apps.wallet_subscriptions w
                            where w.service_key = v_service and w.plan_key = v_plan
                              and w.status = 'active')));
end
$$;

-- Retiring a plan, rather than deleting one somebody is on.
create or replace function qvm_new_apps.admin_integration_plan_retire(
  p_service_key text, p_plan_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare v_subs integer;
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'هذه الصفحة من صلاحية قبارتس', 'data', null);
  end if;

  select count(*) into v_subs from qvm_new_apps.wallet_subscriptions w
   where w.service_key = p_service_key and w.plan_key = p_plan_key and w.status = 'active';

  update qvm_new_apps.integration_plans
     set is_active = false, is_popular = false
   where service_key = p_service_key and plan_key = p_plan_key;

  -- Deactivated, never deleted: a subscription points at this row for its name and its limits,
  -- and removing it would leave live subscribers describing a plan that no longer exists.
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'still_subscribed', v_subs));
end
$$;

-- ── The rates ──────────────────────────────────────────────────────────────────────────────────
create or replace function qvm_new_apps.admin_rate_save(p_rate_key text, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
begin
  if not qvm_new_apps.wallet_is_operator() then
    return jsonb_build_object('status', false, 'message', 'هذه الصفحة من صلاحية قبارتس', 'data', null);
  end if;
  if p_amount is null or p_amount < 0 then
    return jsonb_build_object('status', false, 'message', 'القيمة يجب أن تكون صفرًا أو أكثر', 'data', null);
  end if;
  -- The point price divides; zero would make every AI charge an error rather than a big number.
  if p_rate_key = 'ai_point_sar' and p_amount <= 0 then
    return jsonb_build_object('status', false, 'message', 'سعر النقطة يجب أن يكون أكبر من صفر', 'data', null);
  end if;

  update qvm_new_apps.wallet_rates
     set amount = p_amount, updated_at = now(), updated_by = auth.uid()
   where rate_key = p_rate_key;

  if not found then
    return jsonb_build_object('status', false, 'message', 'هذا المعدل غير موجود', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$$;

grant execute on function qvm_new_apps.admin_integrations_catalogue() to authenticated, service_role;
grant execute on function qvm_new_apps.admin_integration_service_save(jsonb) to authenticated, service_role;
grant execute on function qvm_new_apps.admin_integration_plan_save(jsonb) to authenticated, service_role;
grant execute on function qvm_new_apps.admin_integration_plan_retire(text, text) to authenticated, service_role;
grant execute on function qvm_new_apps.admin_rate_save(text, numeric) to authenticated, service_role;
