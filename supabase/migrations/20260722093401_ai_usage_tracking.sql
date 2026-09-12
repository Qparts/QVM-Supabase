-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- AI usage tracking: one row per AI action taken in the system (precise, per-user, per-vendor).
create table if not exists public.ai_usage_events (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  auth_uid      uuid,
  app_user_id   text,
  user_name     text,
  user_type     text,
  action_type   text not null default 'invoice_ocr',
  source        text,
  model         text,
  status        text not null default 'success',
  error_code    text,
  error_message text,
  vendor_name   text,
  order_number  text,
  file_name     text,
  file_mime     text,
  prompt_tokens integer not null default 0,
  output_tokens integer not null default 0,
  total_tokens  integer not null default 0,
  est_cost_usd  numeric(12,6) not null default 0,
  duration_ms   integer
);
create index if not exists ai_usage_events_created_idx on public.ai_usage_events (created_at desc);
create index if not exists ai_usage_events_user_idx    on public.ai_usage_events (user_name);
create index if not exists ai_usage_events_vendor_idx  on public.ai_usage_events (vendor_name);
create index if not exists ai_usage_events_status_idx  on public.ai_usage_events (status);

-- Estimated cost (USD) from tokens + model. Rates are per 1,000,000 tokens (approx Gemini pricing).
create or replace function public._ai_cost_usd(p_model text, p_in integer, p_out integer)
returns numeric language sql immutable set search_path = '' as $$
  select round(
      (coalesce(p_in,0)  / 1000000.0) * case
          when p_model ilike '%flash-lite%' then 0.10
          when p_model ilike '%flash%'      then 0.30
          when p_model ilike '%pro%'        then 1.25
          else 0.10 end
    + (coalesce(p_out,0) / 1000000.0) * case
          when p_model ilike '%flash-lite%' then 0.40
          when p_model ilike '%flash%'      then 2.50
          when p_model ilike '%pro%'        then 10.00
          else 0.40 end
  , 6);
$$;

-- Insert one usage event. Server captures auth.uid(); client passes denormalized identity + metrics.
create or replace function public.log_ai_usage(
  p_action_type text, p_source text, p_model text, p_status text,
  p_error_code text, p_error_message text, p_vendor_name text, p_order_number text,
  p_file_name text, p_file_mime text,
  p_prompt_tokens integer, p_output_tokens integer, p_total_tokens integer, p_duration_ms integer,
  p_app_user_id text, p_user_name text, p_user_type text
) returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  insert into public.ai_usage_events(
    auth_uid, app_user_id, user_name, user_type, action_type, source, model,
    status, error_code, error_message, vendor_name, order_number, file_name, file_mime,
    prompt_tokens, output_tokens, total_tokens, est_cost_usd, duration_ms
  ) values (
    auth.uid(), p_app_user_id, p_user_name, p_user_type,
    coalesce(nullif(p_action_type,''),'invoice_ocr'), p_source, p_model,
    coalesce(nullif(p_status,''),'success'), p_error_code, left(p_error_message, 1000),
    p_vendor_name, p_order_number, p_file_name, p_file_mime,
    coalesce(p_prompt_tokens,0), coalesce(p_output_tokens,0),
    coalesce(nullif(p_total_tokens,0), coalesce(p_prompt_tokens,0)+coalesce(p_output_tokens,0)),
    public._ai_cost_usd(p_model, p_prompt_tokens, p_output_tokens),
    p_duration_ms
  ) returning id into v_id;
  return v_id;
end $$;
grant execute on function public.log_ai_usage(text,text,text,text,text,text,text,text,text,text,integer,integer,integer,integer,text,text,text) to anon, authenticated;

-- Aggregated report (summary + daily + by user/vendor/model/source) for the tracking page.
create or replace function public.get_ai_usage_report(p_from timestamptz, p_to timestamptz)
returns json language plpgsql security definer set search_path = '' as $$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days');
        v_to   timestamptz := coalesce(p_to, now());
        v_summary json; v_daily json; v_user json; v_vendor json; v_model json; v_source json;
begin
  if auth.uid() is null then
    return json_build_object('status','error','message','unauthorized','data',null);
  end if;

  select json_build_object(
    'requests', count(*),
    'success',  count(*) filter (where status='success'),
    'errors',   count(*) filter (where status<>'success'),
    'prompt_tokens', coalesce(sum(prompt_tokens),0),
    'output_tokens', coalesce(sum(output_tokens),0),
    'total_tokens',  coalesce(sum(total_tokens),0),
    'est_cost_usd',  coalesce(round(sum(est_cost_usd),4),0),
    'users',   count(distinct coalesce(user_name, app_user_id, auth_uid::text)),
    'vendors', count(distinct vendor_name),
    'avg_duration_ms', coalesce(round(avg(duration_ms)),0)
  ) into v_summary
  from public.ai_usage_events where created_at >= v_from and created_at <= v_to;

  select coalesce(json_agg(t order by t.day desc),'[]') into v_daily from (
    select date_trunc('day', created_at)::date as day,
           count(*) requests, count(*) filter (where status<>'success') errors,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),4),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.requests desc),'[]') into v_user from (
    select coalesce(user_name,'—') user_name, max(user_type) user_type,
           count(*) requests, count(*) filter (where status<>'success') errors,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),4),0) est_cost_usd,
           max(created_at) last_at
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.requests desc),'[]') into v_vendor from (
    select coalesce(vendor_name,'—') vendor_name, count(*) requests,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),4),0) est_cost_usd,
           max(created_at) last_at
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.requests desc),'[]') into v_model from (
    select coalesce(model,'—') model, count(*) requests,
           coalesce(sum(total_tokens),0) total_tokens, coalesce(round(sum(est_cost_usd),4),0) est_cost_usd
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  select coalesce(json_agg(t order by t.requests desc),'[]') into v_source from (
    select coalesce(source,'—') source, count(*) requests
    from public.ai_usage_events where created_at >= v_from and created_at <= v_to group by 1
  ) t;

  return json_build_object('status','success','message','OK','data', json_build_object(
    'from', v_from, 'to', v_to, 'summary', v_summary, 'daily', v_daily,
    'by_user', v_user, 'by_vendor', v_vendor, 'by_model', v_model, 'by_source', v_source
  ));
end $$;
grant execute on function public.get_ai_usage_report(timestamptz,timestamptz) to authenticated;

-- Paginated detailed event log for the table.
create or replace function public.get_ai_usage_events(
  p_from timestamptz, p_to timestamptz, p_status text, p_search text, p_limit integer, p_offset integer
) returns json language plpgsql security definer set search_path = '' as $$
declare v_from timestamptz := coalesce(p_from, now() - interval '30 days');
        v_to   timestamptz := coalesce(p_to, now());
        v_rows json; v_total bigint;
begin
  if auth.uid() is null then
    return json_build_object('status','error','message','unauthorized','data',null);
  end if;

  select count(*) into v_total from public.ai_usage_events e
   where e.created_at >= v_from and e.created_at <= v_to
     and (p_status is null or p_status='' or e.status = p_status)
     and (p_search is null or p_search='' or e.user_name ilike '%'||p_search||'%'
          or e.vendor_name ilike '%'||p_search||'%' or e.order_number ilike '%'||p_search||'%'
          or e.file_name ilike '%'||p_search||'%' or e.model ilike '%'||p_search||'%');

  select coalesce(json_agg(r order by r.created_at desc),'[]') into v_rows from (
    select e.id, e.created_at, e.user_name, e.user_type, e.action_type, e.source, e.model,
           e.status, e.error_message, e.vendor_name, e.order_number, e.file_name,
           e.prompt_tokens, e.output_tokens, e.total_tokens, e.est_cost_usd, e.duration_ms
    from public.ai_usage_events e
    where e.created_at >= v_from and e.created_at <= v_to
      and (p_status is null or p_status='' or e.status = p_status)
      and (p_search is null or p_search='' or e.user_name ilike '%'||p_search||'%'
           or e.vendor_name ilike '%'||p_search||'%' or e.order_number ilike '%'||p_search||'%'
           or e.file_name ilike '%'||p_search||'%' or e.model ilike '%'||p_search||'%')
    order by e.created_at desc
    limit greatest(1, least(coalesce(p_limit,50), 500)) offset greatest(0, coalesce(p_offset,0))
  ) r;

  return json_build_object('status','success','message','OK','data', json_build_object('rows', v_rows, 'total', v_total));
end $$;
grant execute on function public.get_ai_usage_events(timestamptz,timestamptz,text,text,integer,integer) to authenticated;
