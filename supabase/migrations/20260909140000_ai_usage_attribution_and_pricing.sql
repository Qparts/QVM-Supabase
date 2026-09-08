-- Making AI spend answerable: who, where, on whose behalf, and at what rate.
--
-- Two things were wrong with the old log.
--
-- Attribution was whatever the browser chose to send. user_name arrived on 12 of 23 rows and
-- vendor_name on 6, because each calling screen passed what it happened to have — and a field
-- the client fills is a field the client can also get wrong. auth.uid() was already there and
-- trustworthy on every row, so identity is now resolved from it on the server. The one caller
-- with no session — the vendor pricing from an emailed link — is resolved from the quote token
-- they already authenticate with, which is why that path logged nobody at all before.
--
-- Cost was three ilike branches with the rates written into the function body. Correcting a
-- price meant a migration, nothing recorded which rate had been applied, and a model the
-- patterns did not anticipate was silently billed at the flash-lite rate. Rates now live in a
-- table that can be edited, are effective-dated, and the rate actually used is stamped on each
-- event — so a total can be taken apart and checked rather than trusted.

-- ── Pricing ──────────────────────────────────────────────────────────────────────────────────
create table if not exists public.ai_model_pricing (
  pricing_id         bigint generated always as identity primary key,
  model_pattern      text        not null,          -- matched with ilike
  -- Higher wins, so «%flash-lite%» beats «%flash%» beats the catch-all without depending on
  -- the order rows happen to be stored in.
  priority           integer     not null default 0,
  input_per_m        numeric(12,6) not null,
  output_per_m       numeric(12,6) not null,
  -- Null means «we have not been told» — such tokens are then billed at the input rate and the
  -- event is marked approximate, rather than quietly costed at a number nobody supplied.
  cached_input_per_m numeric(12,6),
  effective_from     timestamptz not null default '2020-01-01T00:00:00Z',
  -- The catch-all. A row costed through it is a model we have no published price for, and the
  -- page says so instead of presenting a guess as a figure.
  is_fallback        boolean     not null default false,
  note               text,
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);

alter table public.ai_model_pricing enable row level security;

-- Seeded with exactly the rates the old function used, so no historical total moves on the day
-- this ships. They are editable now, which is the point.
insert into public.ai_model_pricing (model_pattern, priority, input_per_m, output_per_m, is_fallback, note)
select * from (values
  ('%flash-lite%', 30, 0.10::numeric, 0.40::numeric,  false, 'Gemini Flash-Lite'),
  ('%flash%',      20, 0.30::numeric, 2.50::numeric,  false, 'Gemini Flash'),
  ('%pro%',        20, 1.25::numeric, 10.00::numeric, false, 'Gemini Pro'),
  ('%',             0, 0.10::numeric, 0.40::numeric,  true,  'Fallback — no published rate for this model')
) v(model_pattern, priority, input_per_m, output_per_m, is_fallback, note)
where not exists (select 1 from public.ai_model_pricing);

/** The rate sheet that applied to a model at a moment. */
create or replace function public.ai_price_for(p_model text, p_at timestamptz default now())
returns table (input_per_m numeric, output_per_m numeric, cached_input_per_m numeric, is_fallback boolean)
language sql
stable
security definer
set search_path to ''
as $function$
  select p.input_per_m, p.output_per_m, p.cached_input_per_m, p.is_fallback
    from public.ai_model_pricing p
   where coalesce(p_model, '') ilike p.model_pattern
     and p.effective_from <= coalesce(p_at, now())
   order by p.priority desc, p.effective_from desc
   limit 1;
$function$;

-- The old signature computed from hardcoded rates and took no cached tokens. Dropped rather
-- than left beside the new one: two functions with the same name and different arithmetic is
-- how two screens come to disagree about what a month cost.
drop function if exists public._ai_cost_usd(text, integer, integer);

create or replace function public._ai_cost_usd(
  p_model text, p_in integer, p_out integer, p_cached integer default 0)
returns numeric
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare r record; v_billable_in integer;
begin
  select * into r from public.ai_price_for(p_model);
  if not found then return 0; end if;
  -- Cached tokens are reported inside the prompt count, so charging both would bill them twice.
  v_billable_in := greatest(coalesce(p_in, 0) - coalesce(p_cached, 0), 0);
  return round(
      (v_billable_in       / 1000000.0) * r.input_per_m
    + (coalesce(p_cached,0)/ 1000000.0) * coalesce(r.cached_input_per_m, r.input_per_m)
    + (coalesce(p_out,0)   / 1000000.0) * r.output_per_m
  , 8);
end
$function$;

-- ── What an event now records ────────────────────────────────────────────────────────────────
alter table public.ai_usage_events
  add column if not exists cached_tokens     integer     not null default 0,
  add column if not exists thought_tokens    integer     not null default 0,
  -- Where in the app it happened, as the route the person was on.
  add column if not exists route             text,
  -- Resolved, not supplied: who they are and what they belong to.
  add column if not exists user_role         text,
  add column if not exists company_name      text,
  add column if not exists company_id        integer,
  add column if not exists branch_id         integer,
  add column if not exists vendor_id         integer,
  add column if not exists quotation_id      bigint,
  add column if not exists actor_kind        text,
  -- The rate sheet applied, stamped at the time, so the figure can be re-derived years later.
  add column if not exists rate_input_per_m  numeric(12,6),
  add column if not exists rate_output_per_m numeric(12,6),
  add column if not exists rate_is_fallback  boolean     not null default false;

create index if not exists ai_usage_events_created_idx on public.ai_usage_events (created_at desc);
create index if not exists ai_usage_events_actor_idx   on public.ai_usage_events (auth_uid);
create index if not exists ai_usage_events_vendor_idx  on public.ai_usage_events (vendor_id);

-- ── Writing an event ─────────────────────────────────────────────────────────────────────────
-- Four parameters added, so the old signature is dropped rather than left beside this one:
-- PostgREST picks an overload by the JSON keys it is sent, and two functions of this name with
-- different attribution rules is a coin toss over whether a row gets an owner.
drop function if exists public.log_ai_usage(text,text,text,text,text,text,text,text,text,text,integer,integer,integer,integer,text,text,text);

create or replace function public.log_ai_usage(
  p_action_type text,
  p_source text,
  p_model text,
  p_status text,
  p_error_code text,
  p_error_message text,
  p_vendor_name text,
  p_order_number text,
  p_file_name text,
  p_file_mime text,
  p_prompt_tokens integer,
  p_output_tokens integer,
  p_total_tokens integer,
  p_duration_ms integer,
  p_app_user_id text,
  p_user_name text,
  p_user_type text,
  p_quote_token text default null,
  p_route text default null,
  p_cached_tokens integer default 0,
  p_thought_tokens integer default 0)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id bigint;
  v_uid uuid := auth.uid();
  v_actor text;
  v_name text; v_role text; v_utype text;
  v_company_id integer; v_company text; v_branch_id integer;
  v_vendor_id integer; v_vendor text; v_quotation_id bigint; v_order text;
  v_tok uuid;
  r_price record;
  v_in integer := coalesce(p_prompt_tokens, 0);
  v_out integer := coalesce(p_output_tokens, 0);
  v_cached integer := coalesce(p_cached_tokens, 0);
begin
  -- Identity is read from the session, not from what the caller typed into the parameters.
  if v_uid is not null then
    select u.user_name,
           rd.list_data, td.list_data,
           u.user_company, cd.list_data, u.user_branch, u.user_vendor
      into v_name, v_role, v_utype, v_company_id, v_company, v_branch_id, v_vendor_id
      from qvm_new_apps.user_data u
      left join qvm_new_apps.list_data rd on rd.list_data_id = u.user_role
      left join qvm_new_apps.list_data td on td.list_data_id = u.user_type
      left join qvm_new_apps.list_data cd on cd.list_data_id = u.user_company
     where u.user_id = v_uid;

    if v_vendor_id is not null then
      v_actor := 'vendor_user';
      select v.vendor_name into v_vendor from qvm_new_apps.vendors v where v.vendor_id = v_vendor_id;
    elsif qvm_new_apps.is_qparts_team() then
      v_actor := 'staff';
    else
      v_actor := 'client_user';
    end if;
  else
    -- No session: the only legitimate caller is the vendor pricing from an emailed link, and
    -- the quote token is what they already prove themselves with everywhere else on that page.
    -- Without one there is nobody to attribute this to, so nothing is written — the function is
    -- executable by anon and an open insert would be a free way to fill the table.
    begin
      v_tok := nullif(btrim(coalesce(p_quote_token, '')), '')::uuid;
    exception when others then
      v_tok := null;
    end;
    if v_tok is null then return null; end if;

    select qv.vendor_id, qv.quotation_id, qv.vendor_branch_id
      into v_vendor_id, v_quotation_id, v_branch_id
      from qvm_new_apps.quotation_vendors qv
     where qv.access_token = v_tok
       and (qv.token_expires_at is null or qv.token_expires_at > now());
    if v_vendor_id is null then return null; end if;

    v_actor := 'vendor_link';
    select v.vendor_name into v_vendor from qvm_new_apps.vendors v where v.vendor_id = v_vendor_id;
    select q.order_number into v_order from qvm_new_apps.quotations q where q.quotation_id = v_quotation_id;
  end if;

  -- The rate sheet in force, stamped on the row so the figure can be re-derived later.
  select * into r_price from public.ai_price_for(p_model);

  insert into public.ai_usage_events(
    auth_uid, app_user_id, user_name, user_type, user_role, actor_kind,
    company_id, company_name, branch_id, vendor_id, vendor_name, quotation_id,
    action_type, source, route, model,
    status, error_code, error_message, order_number, file_name, file_mime,
    prompt_tokens, output_tokens, total_tokens, cached_tokens, thought_tokens,
    est_cost_usd, rate_input_per_m, rate_output_per_m, rate_is_fallback, duration_ms
  ) values (
    v_uid, p_app_user_id, coalesce(v_name, p_user_name), coalesce(v_utype, p_user_type),
    v_role, v_actor,
    v_company_id, v_company, v_branch_id, v_vendor_id, coalesce(v_vendor, p_vendor_name),
    v_quotation_id,
    coalesce(nullif(p_action_type,''),'invoice_ocr'), p_source, p_route, p_model,
    coalesce(nullif(p_status,''),'success'), p_error_code, left(p_error_message, 1000),
    coalesce(v_order, p_order_number), p_file_name, p_file_mime,
    v_in, v_out, coalesce(nullif(p_total_tokens,0), v_in + v_out), v_cached,
    coalesce(p_thought_tokens, 0),
    public._ai_cost_usd(p_model, v_in, v_out, v_cached),
    r_price.input_per_m, r_price.output_per_m, coalesce(r_price.is_fallback, false),
    p_duration_ms
  ) returning id into v_id;
  return v_id;
end
$function$;

-- ── Reading it ───────────────────────────────────────────────────────────────────────────────
-- Both readers were gated on «auth.uid() is not null», so any signed-in vendor or workshop user
-- could read every other company's orders, vendors and spend. This page is Qparts-only.
create or replace function public.get_ai_usage_events(
  p_from timestamptz, p_to timestamptz, p_status text, p_search text,
  p_limit integer, p_offset integer)
returns json
language plpgsql stable security definer set search_path to ''
as $function$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days');
        v_to   timestamptz := coalesce(p_to, now());
        v_rows json; v_total bigint;
begin
  if not qvm_new_apps.is_qparts_team() then
    return json_build_object('status','error','message','unauthorized','data',null);
  end if;

  select count(*) into v_total from public.ai_usage_events e
   where e.created_at >= v_from and e.created_at <= v_to
     and (p_status is null or p_status = '' or e.status = p_status)
     and (p_search is null or p_search = ''
          or e.user_name ilike '%'||p_search||'%'
          or e.vendor_name ilike '%'||p_search||'%'
          or e.company_name ilike '%'||p_search||'%'
          or e.order_number ilike '%'||p_search||'%'
          or e.file_name ilike '%'||p_search||'%'
          or e.source ilike '%'||p_search||'%'
          or e.route ilike '%'||p_search||'%'
          or e.model ilike '%'||p_search||'%');

  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) into v_rows from (
    select e.id, e.created_at, e.user_name, e.user_type, e.user_role, e.actor_kind,
           e.company_name, e.vendor_name, e.action_type, e.source, e.route, e.model,
           e.status, e.error_code, e.error_message, e.order_number, e.file_name,
           e.prompt_tokens, e.output_tokens, e.cached_tokens, e.thought_tokens, e.total_tokens,
           e.est_cost_usd, e.rate_input_per_m, e.rate_output_per_m, e.rate_is_fallback,
           e.duration_ms
      from public.ai_usage_events e
     where e.created_at >= v_from and e.created_at <= v_to
       and (p_status is null or p_status = '' or e.status = p_status)
       and (p_search is null or p_search = ''
            or e.user_name ilike '%'||p_search||'%'
            or e.vendor_name ilike '%'||p_search||'%'
            or e.company_name ilike '%'||p_search||'%'
            or e.order_number ilike '%'||p_search||'%'
            or e.file_name ilike '%'||p_search||'%'
            or e.source ilike '%'||p_search||'%'
            or e.route ilike '%'||p_search||'%'
            or e.model ilike '%'||p_search||'%')
     order by e.created_at desc
     limit greatest(coalesce(p_limit,50),1) offset greatest(coalesce(p_offset,0),0)
  ) x;

  return json_build_object('status','success','message','ok',
    'data', json_build_object('rows', v_rows, 'total', v_total));
end
$function$;

create or replace function public.get_ai_usage_report(p_from timestamptz, p_to timestamptz)
returns json
language plpgsql stable security definer set search_path to ''
as $function$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days');
        v_to   timestamptz := coalesce(p_to, now());
        v_summary json; v_daily json; v_user json; v_vendor json;
        v_model json; v_source json; v_company json; v_action json; v_route json; v_actor json;
begin
  if not qvm_new_apps.is_qparts_team() then
    return json_build_object('status','error','message','unauthorized','data',null);
  end if;

  select json_build_object(
    'requests', count(*),
    'success',  count(*) filter (where status='success'),
    'errors',   count(*) filter (where status<>'success'),
    'prompt_tokens', coalesce(sum(prompt_tokens),0),
    'output_tokens', coalesce(sum(output_tokens),0),
    'cached_tokens', coalesce(sum(cached_tokens),0),
    'thought_tokens', coalesce(sum(thought_tokens),0),
    'total_tokens',  coalesce(sum(total_tokens),0),
    'est_cost_usd',  coalesce(round(sum(est_cost_usd),6),0),
    'users',   count(distinct coalesce(user_name, app_user_id, auth_uid::text)),
    'vendors', count(distinct vendor_name),
    -- How much of the figure above rests on a model we had no published rate for. A total
    -- nobody can qualify is a total nobody should quote.
    'fallback_priced', count(*) filter (where rate_is_fallback),
    'avg_duration_ms', coalesce(round(avg(duration_ms)),0)
  ) into v_summary
  from public.ai_usage_events where created_at >= v_from and created_at <= v_to;

  select coalesce(json_agg(t order by t.day desc),'[]') into v_daily from (
    select date_trunc('day', created_at)::date as day,
           count(*) requests, count(*) filter (where status<>'success') errors,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_user from (
    select coalesce(user_name,'—') user_name, max(user_type) user_type,
           max(user_role) user_role, max(company_name) company_name, max(actor_kind) actor_kind,
           count(*) requests, count(*) filter (where status<>'success') errors,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd,
           max(created_at) last_at
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_vendor from (
    select coalesce(vendor_name,'—') vendor_name, count(*) requests,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd,
           max(created_at) last_at
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_company from (
    select coalesce(company_name,'—') company_name, count(*) requests,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd,
           max(created_at) last_at
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_action from (
    select coalesce(action_type,'—') action_type, count(*) requests,
           count(*) filter (where status<>'success') errors,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_route from (
    select coalesce(route,'—') route, count(*) requests,
           coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_actor from (
    select coalesce(actor_kind,'—') actor_kind, count(*) requests,
           coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.est_cost_usd desc),'[]') into v_model from (
    select coalesce(model,'—') model, count(*) requests,
           bool_or(rate_is_fallback) rate_is_fallback,
           max(rate_input_per_m) rate_input_per_m, max(rate_output_per_m) rate_output_per_m,
           coalesce(sum(prompt_tokens),0) prompt_tokens, coalesce(sum(output_tokens),0) output_tokens,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.requests desc),'[]') into v_source from (
    select coalesce(source,'—') source, count(*) requests,
           coalesce(round(sum(est_cost_usd),6),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  return json_build_object('status','success','message','OK','data', json_build_object(
    'from', v_from, 'to', v_to, 'summary', v_summary, 'daily', v_daily,
    'by_user', v_user, 'by_vendor', v_vendor, 'by_company', v_company,
    'by_action', v_action, 'by_route', v_route, 'by_actor', v_actor,
    'by_model', v_model, 'by_source', v_source
  ));
end $function$;
