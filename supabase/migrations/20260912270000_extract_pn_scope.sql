-- Extract PN respects the account's branches.
--
-- Neither of its two functions had any scoping whatsoever — no branch filter, no internal check —
-- so every account saw every order waiting for a part number, from every branch of every company.
--
-- The queue is filtered, and so is opening a single order: hiding a row from the list is not
-- access control while the id still fetches it, and this page fetches by id.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_extract_pn_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_rows jsonb; v_orders int; v_parts int;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope int[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated', 'data', null);
  end if;

  with pending as (
    -- an order qualifies while it still has at least one part with no PN saved to the order
    select qi.quotation_id
    from qvm_new_apps.quotation_items qi
    where qi.pn_state <> 'saved'
      and qi.item_status = any (array[235, 236])
      -- The queue had no scoping at all: every account saw every order waiting for a part number,
      -- whichever branch or company it belonged to.
      and (v_scope is null or qi.customer_id = any (v_scope))
    group by qi.quotation_id
  ),
  agg as (
    select q.quotation_id,
           q.order_number,
           q.plate_number,
           q.created_at                                             as rfq_date,
           coalesce(bmain.list_data, '')                            as brand,
           coalesce(qi_first.model, '')                             as model,
           coalesce(qi_first.year::text, '')                        as year,
           coalesce(qi_first.vin, '')                               as vin,
           coalesce(cb.branch_name, '')                             as branch_name,
           coalesce(ld_client.list_data, '')                        as client_name,
           coalesce(am.user_name, '')                               as manager,
           count(*)                                                 as total_parts,
           count(*) filter (where qi.pn_state = 'saved')             as saved_parts,
           count(*) filter (where qi.pn_state <> 'saved')            as pending_parts,
           floor(extract(epoch from (now() - q.created_at)) / 60)::int as waiting_minutes,
           q.extract_locked_by,
           q.extract_lock_touched_at,
           (q.extract_locked_by is not null
             and coalesce(q.extract_lock_touched_at, q.extract_locked_at) > now() - interval '30 minutes') as lock_live
    from pending p
    join qvm_new_apps.quotations q       on q.quotation_id = p.quotation_id
    join qvm_new_apps.quotation_items qi on qi.quotation_id = q.quotation_id
                                        and qi.item_status = any (array[235, 236])
    left join lateral (
      select qi2.model, qi2.year, qi2.vin, qi2.main_brand, qi2.customer_id
      from qvm_new_apps.quotation_items qi2
      where qi2.quotation_id = q.quotation_id
      order by qi2.quotation_item_id
      limit 1
    ) qi_first on true
    left join qvm_new_apps.list_data bmain      on bmain.list_data_id = qi_first.main_brand
    left join qvm_new_apps.client_branches cb   on cb.customer_id = qi_first.customer_id
    left join qvm_new_apps.list_data ld_client  on ld_client.list_data_id = cb.list_data_id
    left join qvm_new_apps.user_data am         on am.user_id = q.account_manager
    group by q.quotation_id, q.order_number, q.plate_number, q.created_at, bmain.list_data,
             qi_first.model, qi_first.year, qi_first.vin, cb.branch_name, ld_client.list_data,
             am.user_name, q.extract_locked_by, q.extract_lock_touched_at, q.extract_locked_at
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.waiting_minutes desc), '[]'::jsonb),
         count(*)::int, coalesce(sum(r.pending_parts), 0)::int
  into v_rows, v_orders, v_parts
  from (
    select a.*,
           case when a.lock_live then (select ud.user_name from qvm_new_apps.user_data ud where ud.user_id = a.extract_locked_by) end as locked_by_name,
           (a.lock_live and a.extract_locked_by = v_uid) as locked_by_me,
           case when a.lock_live then floor(extract(epoch from (now() - a.extract_lock_touched_at)) / 60)::int end as locked_minutes
    from agg a
  ) r;

  return jsonb_build_object('status', true, 'message', 'OK', 'data', jsonb_build_object(
    'orders', v_rows, 'total_orders', v_orders, 'total_pending_parts', v_parts
  ));
end $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_extract_pn_order(p_quotation_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid(); v_order jsonb; v_parts jsonb;
  -- NULL for an unrestricted account; the branch list for a scoped one.
  v_scope int[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
begin
  -- Opening an order by id has to be checked too: the queue may hide it, but the id is guessable
  -- and the page fetches straight from it.
  if v_scope is not null and not exists (
       select 1 from qvm_new_apps.quotation_items qi
        where qi.quotation_id = p_quotation_id and qi.customer_id = any (v_scope)) then
    return jsonb_build_object('status', false, 'message', 'Not found', 'data', null);
  end if;

  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;

  select to_jsonb(o) into v_order from (
    select q.quotation_id, q.order_number, q.plate_number, q.created_at as rfq_date,
           coalesce(bmain.list_data,'') as brand, coalesce(f.model,'') as model,
           coalesce(f.year::text,'') as year, coalesce(f.vin,'') as vin,
           coalesce(cb.branch_name,'') as branch_name, coalesce(ldc.list_data,'') as client_name,
           coalesce(am.user_name,'') as manager,
           greatest(0, (extract(epoch from (now() - q.created_at)) / 60)::int) as waiting_minutes,
           q.extract_locked_by,
           (q.extract_locked_by is not null and coalesce(q.extract_lock_touched_at, q.extract_locked_at) > now() - interval '30 minutes') as lock_live,
           (select ud.user_name from qvm_new_apps.user_data ud where ud.user_id = q.extract_locked_by) as locked_by_name,
           (q.extract_locked_by = v_uid) as locked_by_me,
           (select count(*) from qvm_new_apps.quotation_items u
             where u.quotation_id = q.quotation_id and u.extraction_status = 'unclear')::int as unclear_count
    from qvm_new_apps.quotations q
    left join lateral (
      select qi2.model, qi2.year, qi2.vin, qi2.main_brand, qi2.customer_id
      from qvm_new_apps.quotation_items qi2 where qi2.quotation_id = q.quotation_id
      order by qi2.quotation_item_id limit 1
    ) f on true
    left join qvm_new_apps.list_data bmain on bmain.list_data_id = f.main_brand
    left join qvm_new_apps.client_branches cb on cb.customer_id = f.customer_id
    left join qvm_new_apps.list_data ldc on ldc.list_data_id = cb.list_data_id
    left join qvm_new_apps.user_data am on am.user_id = q.account_manager
    where q.quotation_id = p_quotation_id
  ) o;

  if v_order is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_id'); end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.added_at_extraction desc nulls last,
                                                p.quotation_item_id desc), '[]'::jsonb)
    into v_parts from (
    select qi.quotation_item_id, coalesce(qi.part_description,'') as part_description,
           coalesce(qi.part_number,'') as part_number,
           coalesce(qi.draft_part_number,'') as draft_part_number,
           qi.pn_state, qi.quantity,
           qi.extraction_status, qi.extraction_unclear_reason,
           coalesce((select ud.user_name from qvm_new_apps.user_data ud
                      where ud.user_id = qi.extraction_flagged_by), '') as unclear_by,
           coalesce(qi.added_at_extraction, false) as added_at_extraction,
           (coalesce(qi.added_at_extraction, false) and qi.created_by = v_uid) as can_remove,
           coalesce((select jsonb_agg(a.alt_part_number order by a.alt_pn_id)
                     from qvm_new_apps.quotation_item_alt_pns a
                     where a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alt_pns
    from qvm_new_apps.quotation_items qi
    where qi.quotation_id = p_quotation_id and qi.item_status = any (array[235, 236])
  ) p;

  return jsonb_build_object('status', true, 'message', 'OK',
    'data', jsonb_build_object('order', v_order, 'parts', v_parts));
end $function$;
