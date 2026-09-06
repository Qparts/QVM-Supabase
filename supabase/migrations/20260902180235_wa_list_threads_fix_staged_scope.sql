-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The counters were built in a second statement, where the CTEs of the first no longer
-- exist. Everything now comes out of one statement, so `staged` is in scope for both the
-- rows and the counts that describe them.

create or replace function qvm_new_apps.wa_list_threads(
  p_status text default null,
  p_search text default null,
  p_only_mine boolean default false,
  p_limit integer default 50,
  p_offset integer default 0,
  p_channel text default null,
  p_wa_account_id bigint default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_rows jsonb; v_total bigint; v_counters jsonb;
  v_q text := nullif(btrim(coalesce(p_search,'')),'');
  v_ids bigint[];
  -- 236 Extract PN → 235 Ready For Quotation → 237 Sent To Vendor → 17 Priced.
  -- Priced belongs here: the quote is not finished with until somebody confirms it.
  k_pricing constant int[] := array[15, 16, 17, 235, 236, 237];
  -- 19 Confirmed → 21 Processing → 22 Out for Delivery. Delivered and settled are in
  -- neither list on purpose — a finished order is not work in progress.
  k_doing   constant int[] := array[19, 21, 22];
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- The whole of this screen's access control is these three lines. A number the caller
  -- is not a member of is not filtered out of the results — it never enters them.
  if p_wa_account_id is not null then
    perform qvm_new_apps.wa_require(p_wa_account_id, 'viewer');
    v_ids := array[p_wa_account_id];
  else
    v_ids := qvm_new_apps.wa_my_account_ids();
  end if;

  with scoped as (
    select t.thread_id, t.status, t.unread_count, t.last_message_at, t.last_message_preview,
           t.assigned_to, t.quotation_id, t.channel, t.subject, t.wa_account_id,
           a.label as wa_account_label, a.phone_e164 as wa_account_phone,
           (t.typing_until is not null and t.typing_until > now()) as is_typing,
           c.wa_contact_id, c.phone_e164, c.display_name, c.vendor_id, c.avatar_path, c.chat_type,
           c.email,
           v.vendor_name, ud.user_name as assigned_to_name, q.order_number
      from qvm_new_apps.wa_threads t
      join qvm_new_apps.wa_contacts c on c.wa_contact_id = t.wa_contact_id
      left join qvm_new_apps.wa_accounts a on a.wa_account_id = t.wa_account_id
      left join qvm_new_apps.vendors    v  on v.vendor_id    = c.vendor_id
      left join qvm_new_apps.user_data  ud on ud.user_id     = t.assigned_to
      left join qvm_new_apps.quotations q  on q.quotation_id = t.quotation_id
     where t.deleted_at is null
       and t.wa_account_id = any(v_ids)
  ),
  -- Every thread in scope, stamped with the stages its orders are in. Computed before
  -- the filter rather than inside it, because the tab counts describe the whole inbox
  -- and the list describes one tab of it.
  staged as (
    select s.*,
      exists (
        select 1 from qvm_new_apps.quotation_items qi
         where qi.item_status = any(k_pricing)
           and (qi.quotation_id = s.quotation_id
                or (s.vendor_id is not null and qi.quotation_id in (
                      select qv.quotation_id from qvm_new_apps.quotation_vendors qv
                       where qv.vendor_id = s.vendor_id)))
      ) as in_pricing,
      exists (
        select 1 from qvm_new_apps.quotation_items qi
         where qi.item_status = any(k_doing)
           and (qi.quotation_id = s.quotation_id
                or (s.vendor_id is not null and qi.quotation_id in (
                      select qv.quotation_id from qvm_new_apps.quotation_vendors qv
                       where qv.vendor_id = s.vendor_id)))
      ) as in_processing
    from scoped s
  ),
  base as (
    select st.* from staged st
     where (p_status is null
            or (p_status = 'pricing'    and st.in_pricing)
            or (p_status = 'processing' and st.in_processing)
            or (p_status in ('open', 'pending', 'closed') and st.status = p_status))
       and (p_channel is null or st.channel = p_channel)
       and (not p_only_mine or st.assigned_to = auth.uid())
       and (v_q is null
            or st.phone_e164 ilike '%'||v_q||'%'
            or st.email ilike '%'||v_q||'%'
            or st.display_name ilike '%'||v_q||'%'
            or st.subject ilike '%'||v_q||'%'
            or st.vendor_name ilike '%'||v_q||'%'
            or st.last_message_preview ilike '%'||v_q||'%'
            or st.order_number ilike '%'||v_q||'%'
            or exists (select 1 from qvm_new_apps.wa_messages m
                        where m.thread_id = st.thread_id and m.deleted_at is null
                          and m.body ilike '%'||v_q||'%')
            or exists (select 1 from qvm_new_apps.quotation_items qi
                        where qi.quotation_id = st.quotation_id
                          and (qi.part_number ilike '%'||v_q||'%'
                               or qi.part_description ilike '%'||v_q||'%')))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.last_message_at desc nulls last), '[]'::jsonb),
         (select count(*) from base),
         -- Scoped to the same numbers as the list. Left unscoped these counters would have
         -- reported the whole company's unread total to whoever opened the page.
         (select jsonb_build_object(
             'open',       count(*) filter (where status='open'),
             'pending',    count(*) filter (where status='pending'),
             'closed',     count(*) filter (where status='closed'),
             'pricing',    count(*) filter (where in_pricing),
             'processing', count(*) filter (where in_processing),
             'mine',       count(*) filter (where assigned_to = auth.uid() and status <> 'closed'),
             'unassigned', count(*) filter (where assigned_to is null and status <> 'closed'),
             'unread',     coalesce(sum(unread_count) filter (where status<>'closed'),0))
           from staged)
    into v_rows, v_total, v_counters
    from (select * from base order by last_message_at desc nulls last
           limit greatest(coalesce(p_limit,50),1) offset greatest(coalesce(p_offset,0),0)) x;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('threads', v_rows, 'total', v_total, 'counters', v_counters));
end $function$;
