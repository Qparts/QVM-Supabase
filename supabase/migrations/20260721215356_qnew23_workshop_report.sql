-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.get_workshop_report(
  p_from timestamptz default null, p_to timestamptz default null, p_employee uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_from timestamptz := coalesce(p_from, '2000-01-01'::timestamptz);
  v_to   timestamptz := coalesce(p_to,   now());
  v_admin boolean := qvm_new_apps.is_report_admin();
  v_emp uuid;
  v_total_requests int; v_total_items int;
  v_volume jsonb; v_by_city jsonb;
  v_time jsonb; v_threshold numeric;
  v_early int; v_late int; v_late_add int; v_notes int;
  v_spend numeric; v_weekly jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'No session', 'data', null);
  end if;
  if v_admin then v_emp := p_employee; else v_emp := auth.uid(); end if;

  select value into v_threshold from qvm_new_apps.report_settings_thresholds
   where key = 'workshop_response_speed_threshold_hours';

  select count(*) into v_total_requests
  from qvm_new_apps.quotations q where q.created_at >= v_from and q.created_at <= v_to;

  select count(*) into v_total_items
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where q.created_at >= v_from and q.created_at <= v_to;

  select coalesce(jsonb_agg(jsonb_build_object(
     'user_id', e.service_advisor, 'user_name', ud.user_name, 'role', rl.list_data,
     'requests', e.requests, 'items', e.items,
     'contribution_pct', case when v_total_requests>0 then round(100.0*e.requests/v_total_requests,1) else 0 end)
     order by e.requests desc), '[]'::jsonb)
  into v_volume
  from (
    select q.service_advisor,
      count(distinct q.quotation_id) AS requests,
      count(qi.quotation_item_id) AS items
    from qvm_new_apps.quotations q
    left join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
    where q.created_at >= v_from and q.created_at <= v_to
      and (v_emp is null or q.service_advisor = v_emp)
    group by q.service_advisor
  ) e
  left join qvm_new_apps.user_data ud on ud.user_id = e.service_advisor
  left join qvm_new_apps.list_data rl on rl.list_data_id = ud.user_role;

  select coalesce(jsonb_agg(jsonb_build_object('city', city, 'requests', c) order by c desc), '[]'::jsonb)
  into v_by_city
  from (
    select cb.city, count(distinct q.quotation_id) AS c
    from qvm_new_apps.quotations q
    join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
    join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
    where q.created_at >= v_from and q.created_at <= v_to and cb.city is not null
      and (v_emp is null or q.service_advisor = v_emp)
    group by cb.city
  ) z;

  with sl as (
    select coalesce(s.quotation_item_id, ci.quotation_item_id) AS qiid, s.item_status, s.created_at
    from qvm_new_apps.status_logs s
    left join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = s.confirmed_item_id
  ),
  spans as (
    select q.service_advisor, qvm_new_apps.business_minutes(t.t_conf, t.t_sign) AS bmin
    from (
      select qiid,
        min(created_at) filter (where item_status = 19) AS t_conf,
        min(created_at) filter (where item_status = 23) AS t_sign
      from sl group by qiid
    ) t
    join qvm_new_apps.quotation_items qi on qi.quotation_item_id = t.qiid
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    where t.t_conf is not null and t.t_sign is not null and t.t_sign > t.t_conf
      and q.created_at >= v_from and q.created_at <= v_to
      and (v_emp is null or q.service_advisor = v_emp)
  )
  select jsonb_build_object(
    'avg_response_min', coalesce(round(avg(bmin),1),0),
    'sample_count', count(*),
    'threshold_hours', v_threshold,
    'over_threshold', count(*) filter (where v_threshold is not null and bmin > v_threshold*60),
    'by_employee', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', x.service_advisor, 'user_name', ud.user_name,
               'avg_response_min', x.avg_bmin, 'items', x.items) order by x.avg_bmin desc)
      from (select s2.service_advisor, round(avg(s2.bmin),1) AS avg_bmin, count(*) AS items
            from spans s2 group by s2.service_advisor) x
      left join qvm_new_apps.user_data ud on ud.user_id = x.service_advisor), '[]'::jsonb)
  ) into v_time from spans;

  select count(*) into v_early
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.cancellation_reason is not null
    and not exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id = qi.quotation_item_id)
    and q.created_at >= v_from and q.created_at <= v_to
    and (v_emp is null or q.service_advisor = v_emp);

  select count(*) into v_late
  from qvm_new_apps.confirmed_items ci
  join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where (ci.cancellation_reason is not null or ci.client_return_reason is not null)
    and q.created_at >= v_from and q.created_at <= v_to
    and (v_emp is null or q.service_advisor = v_emp);

  select count(*) into v_late_add
  from qvm_new_apps.quotation_items qi
  join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
  where qi.created_at > q.created_at + interval '1 hour'
    and q.created_at >= v_from and q.created_at <= v_to
    and (v_emp is null or q.service_advisor = v_emp);

  select count(*) into v_notes
  from qvm_new_apps.notes n
  where coalesce(n.is_internal, false) is true and coalesce(n.is_deleted,false) = false
    and n.created_at >= v_from and n.created_at <= v_to
    and (v_emp is null or n.user_id = v_emp);

  with wk as (
    select date_trunc('week', qi.created_at) AS wkstart, sum(qi.total_price_before_vat) AS spend
    from qvm_new_apps.quotation_items qi
    join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
    where exists (select 1 from qvm_new_apps.confirmed_items ci where ci.quotation_item_id = qi.quotation_item_id)
      and q.created_at >= v_from and q.created_at <= v_to
      and (v_emp is null or q.service_advisor = v_emp)
    group by date_trunc('week', qi.created_at)
  )
  select coalesce(sum(spend),0)::numeric,
    coalesce(jsonb_agg(jsonb_build_object('week', to_char(wkstart,'YYYY-MM-DD'),
             'spend', round(spend::numeric,2)) order by wkstart), '[]'::jsonb)
  into v_spend, v_weekly from wk;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'is_admin', v_admin, 'scoped_to_self', (not v_admin),
    'volume', jsonb_build_object('total_requests', v_total_requests, 'total_items', v_total_items,
        'by_employee', v_volume, 'by_city', v_by_city),
    'time', v_time,
    'quality', jsonb_build_object('early_cancellations', v_early, 'late_cancellations', v_late,
        'late_additions', v_late_add, 'internal_notes', v_notes),
    'financial', jsonb_build_object('total_spend', round(v_spend,2), 'weekly', v_weekly)
  ));
end; $$;

grant execute on function qvm_new_apps.get_workshop_report(timestamptz,timestamptz,uuid) to authenticated;
notify pgrst, 'reload schema';
