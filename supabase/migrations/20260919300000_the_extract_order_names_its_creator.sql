-- The Extract PN order names its creator.
--
-- The extractor's question about a part is now a decision note to the user who created the order,
-- tagged by default. The order header carries who that is: the user the RFQ form recorded, else
-- the earliest line's creator, else the first author in the lines' status history.
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
           coalesce(q.service_advisor, cr.user_id) as created_by,
           coalesce((select sa.user_name from qvm_new_apps.user_data sa where sa.user_id = q.service_advisor), cr.user_name, '') as created_by_name,
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
    -- Who created the order: the user the RFQ form recorded (service_advisor); failing that, the
    -- earliest line's creator, or whoever wrote the first status log on any of its lines.
    left join lateral (
      select ud.user_id, ud.user_name
        from (
          select qi3.created_by as uid, qi3.created_at
            from qvm_new_apps.quotation_items qi3
           where qi3.quotation_id = q.quotation_id and qi3.created_by is not null
          union all
          select sl.status_changed_by, sl.created_at
            from qvm_new_apps.status_logs sl
            join qvm_new_apps.quotation_items qi4 on qi4.quotation_item_id = sl.quotation_item_id
           where qi4.quotation_id = q.quotation_id and sl.status_changed_by is not null
        ) x
        join qvm_new_apps.user_data ud on ud.user_id = x.uid
       order by x.created_at
       limit 1
    ) cr on true
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
           -- Added here and not yet approved by the workshop: shown, but not part of the order yet.
           (qi.item_status = (select ld.list_data_id from qvm_new_apps.list_data ld
                               where ld.list_id = 3 and ld.list_data = 'Pending Workshop Approval' limit 1)) as awaiting_workshop,
           coalesce((select bc.list_data from qvm_new_apps.list_data bc where bc.list_data_id = qi.brand_class), '') as brand_class_name,
           coalesce((select jsonb_agg(a.alt_part_number order by a.alt_pn_id)
                     from qvm_new_apps.quotation_item_alt_pns a
                     where a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alt_pns,
           -- Alternative items on the line: the extractor's own, and the vendors'.
           coalesce((select jsonb_agg(jsonb_build_object(
                       'alternative_id', al.alternative_id, 'source', al.source, 'part_number', al.part_number,
                       'brand_class_name', bc.list_data, 'brand_name', br.list_data,
                       'origin', coalesce(oc.name_ar, oc.name_en), 'note', al.note,
                       'visible_to_workshop', al.visible_to_workshop,
                       'vendor_name', (select v3.vendor_name from qvm_new_apps.quotation_vendor_items q3
                                         join qvm_new_apps.vendors v3 on v3.vendor_id = q3.vendor_id where q3.cost_id = al.cost_id),
                       'can_remove', al.source = 'qparts') order by al.source desc, al.alternative_id)
                     from qvm_new_apps.quotation_vendor_item_alternatives al
                     left join qvm_new_apps.list_data bc on bc.list_data_id = al.brand_class
                     left join qvm_new_apps.list_data br on br.list_data_id = al.brand_id
                     left join qvm_new_apps.origin_countries oc on oc.origin_country_id = al.origin_country_id
                     where al.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alternatives
    from qvm_new_apps.quotation_items qi
    where qi.quotation_id = p_quotation_id
      and (qi.item_status = any (array[235, 236])
           or qi.item_status = (select ld.list_data_id from qvm_new_apps.list_data ld
                                 where ld.list_id = 3 and ld.list_data = 'Pending Workshop Approval' limit 1))
  ) p;

  return jsonb_build_object('status', true, 'message', 'OK',
    'data', jsonb_build_object('order', v_order, 'parts', v_parts));
end $function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 34 $$;
