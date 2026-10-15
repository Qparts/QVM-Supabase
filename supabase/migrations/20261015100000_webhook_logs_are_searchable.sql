-- The Webhook Logs page becomes a worklist: find a send by order, vehicle or vendor, narrow it by
-- trigger, outcome and date, and see at a glance how many were delivered or failed and which orders
-- were sent more than once.
--
-- list_webhook_logs keeps its four arguments (so an older page still works) and gains:
--   p_search  — matched against the reference id and anywhere in the payload (order number, VIN,
--               plate, make, model, vendor names, part numbers and descriptions);
--   p_since   — only attempts at or after this moment (today / last 7 days on the page).
-- Each row also carries, for the filtered set, how many were delivered and how many failed, and
-- for its own order and trigger, how many attempts exist in total.
drop function if exists qvm_new_apps.list_webhook_logs(text, text, integer, integer);

create or replace function qvm_new_apps.list_webhook_logs(
  p_trigger_type text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null,
  p_since timestamptz default null
)
returns table(
  id bigint, trigger_type text, reference_id integer, request_url text, request_payload jsonb,
  response_status integer, response_body text, status text, created_at timestamptz,
  total_count bigint, delivered_count bigint, failed_count bigint, sends_for_reference bigint
)
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  -- The search is literal: % and _ typed in it are characters, not wildcards.
  v_like text := '%' || replace(replace(replace(coalesce(v_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
begin
  if not qvm_new_apps.is_internal_user() then
    raise exception 'Not authorized';
  end if;

  return query
  with sends as (
    select w.trigger_type, w.reference_id, count(*)::bigint as n
      from qvm_new_apps.webhook_logs w
     group by w.trigger_type, w.reference_id
  ),
  f as (
    select l.*
      from qvm_new_apps.webhook_logs l
     where (p_trigger_type is null or l.trigger_type = p_trigger_type)
       and (p_status is null or l.status = p_status)
       and (p_since is null or l.created_at >= p_since)
       and (v_q is null
            or l.reference_id::text = v_q
            or l.request_payload::text ilike v_like
            or l.request_url ilike v_like)
  )
  select f.id, f.trigger_type, f.reference_id, f.request_url, f.request_payload,
         f.response_status, f.response_body, f.status, f.created_at,
         count(*) over ()::bigint,
         count(*) filter (where f.status = 'success') over ()::bigint,
         count(*) filter (where f.status = 'failed') over ()::bigint,
         coalesce(s.n, 1)
    from f
    left join sends s on s.trigger_type = f.trigger_type and s.reference_id is not distinct from f.reference_id
   order by f.created_at desc
   limit least(greatest(p_limit, 1), 200)
  offset greatest(p_offset, 0);
end;
$function$;

revoke all on function qvm_new_apps.list_webhook_logs(text, text, integer, integer, text, timestamptz) from public;
grant execute on function qvm_new_apps.list_webhook_logs(text, text, integer, integer, text, timestamptz) to authenticated, service_role;

notify pgrst, 'reload schema';
