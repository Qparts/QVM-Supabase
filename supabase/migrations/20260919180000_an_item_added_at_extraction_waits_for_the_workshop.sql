-- An item added at extraction waits for the workshop.
--
-- The Extract PN page's Add item takes the same data a vendor's suggestion takes — description, part
-- number, quantity, type (required), note — and, like a vendor's suggestion, the part is not part of
-- the order until the workshop approves it: it lands in Pending Workshop Approval, the workshop is
-- told, and approval sends it into the normal flow (Ready For Quotation with a number, Extract PN
-- without). The extract list shows it meanwhile, flagged as awaiting.
-- The extract page's add: the vendor form's data, and the workshop's approval before it counts.
DROP FUNCTION IF EXISTS qvm_new_apps.add_extract_item(integer, text, text, text);
DROP FUNCTION IF EXISTS public.add_extract_item(integer, text, text, text);
CREATE OR REPLACE FUNCTION qvm_new_apps.add_extract_item(
  p_quotation_id integer, p_part_description text, p_part_number text DEFAULT NULL, p_alt_part_number text DEFAULT NULL,
  p_quantity integer DEFAULT 1, p_brand_class integer DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lock    uuid;
  v_res     jsonb;
  v_id      int;
  v_desc    text := btrim(coalesce(p_part_description, ''));
  v_pn      text := nullif(btrim(coalesce(p_part_number, '')), '');
  v_alt     text := nullif(btrim(coalesce(p_alt_part_number, '')), '');
  v_pending int;
  v_order   text;
begin
  if v_desc = '' then
    return jsonb_build_object('status', false, 'message', 'Part description is required');
  end if;
  if p_brand_class is null or not exists (select 1 from qvm_new_apps.list_data ld where ld.list_data_id = p_brand_class) then
    return jsonb_build_object('status', false, 'message', 'Pick the item type');
  end if;

  select extract_locked_by into v_lock from qvm_new_apps.quotations where quotation_id = p_quotation_id;
  if v_lock is not null and v_lock <> auth.uid() then
    return jsonb_build_object('status', false, 'message', 'This order is locked by another extractor');
  end if;

  -- Created the way every line is created; the part number is held as a draft, as before.
  v_res := public.add_rfq_item_inline(
    p_quotation_id     := p_quotation_id,
    p_part_number      := null,
    p_part_description := v_desc,
    p_quantity         := greatest(coalesce(p_quantity, 1), 1),
    p_brand_class      := p_brand_class,
    p_part_photo       := null,
    p_initial_note     := nullif(btrim(coalesce(p_note, '')), ''),
    p_from_frontend    := true
  );
  if coalesce(v_res ->> 'status', '') <> 'success' then
    return jsonb_build_object('status', false, 'message', coalesce(v_res ->> 'message', 'Could not add the item'));
  end if;
  v_id := (v_res ->> 'quotation_item_id')::int;

  select list_data_id into v_pending from qvm_new_apps.list_data where list_id = 3 and list_data = 'Pending Workshop Approval' limit 1;

  -- Not part of the order until the workshop says so.
  update qvm_new_apps.quotation_items
     set added_at_extraction = true,
         draft_part_number   = case when v_pn is not null then upper(v_pn) end,
         pn_state            = case when v_pn is not null then 'draft' else 'none' end,
         item_status         = coalesce(v_pending, item_status),
         updated_at          = now()
   where quotation_item_id = v_id;

  perform qvm_new_apps._log_extract_event(v_id, 'item_added', null, v_desc);

  if v_alt is not null then
    insert into qvm_new_apps.quotation_item_alt_pns (quotation_item_id, alt_part_number, created_by)
    values (v_id, upper(v_alt), auth.uid())
    on conflict do nothing;
    perform qvm_new_apps._log_extract_event(v_id, 'alt_added', null, upper(v_alt));
  end if;

  perform qvm_new_apps._touch_extract_lock(p_quotation_id);

  -- The workshop hears about it the way it hears about a vendor's suggestion.
  select order_number into v_order from qvm_new_apps.quotations where quotation_id = p_quotation_id;
  with sent as (
    insert into qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
    select 'قطعة مضافة بانتظار موافقتك',
           'أضاف فريق Qparts القطعة ' || coalesce(v_pn, v_desc) || ' إلى الطلب ' || coalesce(v_order, ''),
           jsonb_build_object('quotation_id', p_quotation_id, 'quotation_item_id', v_id),
           'user', w, auth.uid()
      from qvm_new_apps.workshop_users_for_quotation(p_quotation_id) as w
    returning id, target_user_id
  )
  insert into qvm_new_apps.notification_reads (notification_id, user_id)
  select sent.id, sent.target_user_id from sent where sent.target_user_id is not null;

  return jsonb_build_object('status', true, 'message', 'Item added — awaiting the workshop',
                            'data', jsonb_build_object('quotation_item_id', v_id, 'awaiting_workshop', v_pending is not null));
end;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.add_extract_item(integer, text, text, text, integer, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.add_extract_item(integer, text, text, text, integer, integer, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_decide_added_item(
  p_quotation_item_id bigint, p_approve boolean, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_pending integer;
  v_sent    integer;
  v_cancel  integer;
  v_cur     integer;
  v_qid     bigint;
  v_new     integer;
BEGIN
  SELECT list_data_id INTO v_pending
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Pending Workshop Approval' LIMIT 1;
  SELECT list_data_id INTO v_sent
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor' LIMIT 1;
  SELECT list_data_id INTO v_cancel
    FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Cancelled' LIMIT 1;

  SELECT qi.item_status, qi.quotation_id INTO v_cur, v_qid
    FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id;

  IF v_cur IS NULL THEN RAISE EXCEPTION 'Item not found'; END IF;
  IF v_cur <> v_pending THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This part is not waiting on the workshop');
  END IF;

  -- The workshop the part was sent to, or the Qparts team acting for them when they ask by phone.
  IF NOT (auth.uid() IN (SELECT qvm_new_apps.workshop_users_for_quotation(v_qid))
          OR qvm_new_apps.is_qparts_team()) THEN
    RAISE EXCEPTION 'This part was not sent to you';
  END IF;

  -- Approved: a part a vendor suggested already has that vendor's price on it, so it is Sent To
  -- Vendor; a part the Qparts team added has no vendor yet, so it joins the normal flow — Ready For
  -- Quotation with a part number, Extract PN without (and the auto-RFQ rules see it arrive).
  v_new := CASE WHEN NOT p_approve THEN v_cancel
                WHEN EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_items qvi WHERE qvi.quotation_item_id = p_quotation_item_id) THEN v_sent
                WHEN EXISTS (SELECT 1 FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_quotation_item_id AND COALESCE(btrim(qi.part_number), '') <> '') THEN 235
                ELSE 236 END;

  UPDATE qvm_new_apps.quotation_items
     SET item_status = v_new, updated_at = now()
   WHERE quotation_item_id = p_quotation_item_id;

  IF NOT p_approve AND COALESCE(btrim(p_reason), '') <> '' THEN
    BEGIN
      PERFORM public.upsert_note_inline(
        p_note_type := 'quotation_items', p_type_id := p_quotation_item_id,
        p_note_description := 'Workshop rejected: ' || p_reason, p_note_id := NULL,
        p_is_internal := false);
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'item_status', v_new);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_suggested_items(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'quotation_item_id', qi.quotation_item_id,
             'part_number',       qi.part_number,
             'part_description',  qi.part_description,
             'quantity',          qi.quantity,
             'item_status',       qi.item_status,
             'item_status_name',  ld.list_data,
             'stage', CASE WHEN ld.list_data = 'Added by Vendor' THEN 'qparts'
                           ELSE 'workshop' END,
             'suggested_by_vendor', (SELECT v.vendor_name
                                       FROM qvm_new_apps.quotation_vendor_items qvi
                                       LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = qvi.vendor_id
                                      WHERE qvi.quotation_item_id = qi.quotation_item_id
                                      ORDER BY qvi.cost_id LIMIT 1),
             'suggested_by_user', (SELECT ud.user_name FROM qvm_new_apps.user_data ud WHERE ud.user_id = qi.created_by),
             'brand_class_name', (SELECT bc.list_data FROM qvm_new_apps.list_data bc WHERE bc.list_data_id = qi.brand_class),
             'cost', (SELECT qvi2.cost FROM qvm_new_apps.quotation_vendor_items qvi2
                       WHERE qvi2.quotation_item_id = qi.quotation_item_id
                       ORDER BY qvi2.cost_id LIMIT 1),
             'created_at', qi.created_at) ORDER BY qi.quotation_item_id)
      FROM qvm_new_apps.quotation_items qi
      JOIN qvm_new_apps.list_data ld ON ld.list_data_id = qi.item_status
     WHERE qi.quotation_id = p_quotation_id
       AND ld.list_id = 3
       AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval')), '[]'::jsonb);
$function$;

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
           -- Added here and not yet approved by the workshop: shown, but not part of the order yet.
           (qi.item_status = (select ld.list_data_id from qvm_new_apps.list_data ld
                               where ld.list_id = 3 and ld.list_data = 'Pending Workshop Approval' limit 1)) as awaiting_workshop,
           coalesce((select bc.list_data from qvm_new_apps.list_data bc where bc.list_data_id = qi.brand_class), '') as brand_class_name,
           coalesce((select jsonb_agg(a.alt_part_number order by a.alt_pn_id)
                     from qvm_new_apps.quotation_item_alt_pns a
                     where a.quotation_item_id = qi.quotation_item_id), '[]'::jsonb) as alt_pns
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
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 22 $$;
