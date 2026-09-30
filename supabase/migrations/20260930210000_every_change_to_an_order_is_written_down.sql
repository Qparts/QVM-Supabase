-- Every change to an order is written down.
--
-- The Status Logs page showed the item status changes and little else. From here on, every insert,
-- update and delete on the tables an order lives in — the order, its lines, the vendors asked and
-- their prices, the confirmation, the purchase orders and their lines, the deliveries, the
-- returns, the cancellations, the notes — is written to quotation_audit_log by one trigger, with
-- the columns that changed (old and new) and who did it. Nothing on an order or its items can
-- change without leaving a row here; the business write itself is never blocked by the log.
--
-- quotation_activity(p_order_number) reads the whole story of an order: the rows written here
-- since this migration, and, for the time before it, the logs that already existed (status
-- changes, part-number changes, vendor prices, pricing-page prices, the activity feed,
-- confirmations, purchase orders, delivery notes, approved returns, cancellations, notes) —
-- each described in words, with ids resolved to names.

set search_path to qvm_new_apps, public;

-- ───────────────────────── the log ─────────────────────────

create table if not exists qvm_new_apps.quotation_audit_log (
  audit_id          bigserial primary key,
  quotation_id      integer not null,
  quotation_item_id integer,
  source_table      text not null,
  source_id         bigint,
  action            text not null check (action in ('insert', 'update', 'delete')),
  -- {column: {"old": ..., "new": ...}} — for an insert only "new", for a delete only "old".
  changes           jsonb not null default '{}'::jsonb,
  actor             uuid,
  created_at        timestamptz not null default now()
);
create index if not exists quotation_audit_log_by_order on qvm_new_apps.quotation_audit_log (quotation_id, created_at);
create index if not exists quotation_audit_log_by_item on qvm_new_apps.quotation_audit_log (quotation_item_id) where quotation_item_id is not null;
grant select on qvm_new_apps.quotation_audit_log to service_role;

-- When the log began: the reader takes the older logs only for the time before this.
create table if not exists qvm_new_apps.quotation_audit_start (started_at timestamptz not null);
insert into qvm_new_apps.quotation_audit_start (started_at)
select now() where not exists (select 1 from qvm_new_apps.quotation_audit_start);

create or replace function qvm_new_apps.quotation_audit_started_at()
 returns timestamptz language sql stable as $$ select min(started_at) from qvm_new_apps.quotation_audit_start $$;

-- ───────────────────────── the trigger ─────────────────────────

-- One function for every table. Its argument says how a row finds its order.
create or replace function qvm_new_apps.audit_quotation_change()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_new jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_old jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_how text := tg_argv[0];
  v_qid integer;
  v_item integer;
  v_ci integer;
  v_co integer;
  v_changes jsonb := '{}'::jsonb;
  v_actor uuid;
  v_key text;
  -- Columns that are bookkeeping, not a change anyone did.
  v_skip text[] := array['created_at','updated_at','updated_by','created_by','uploaded_at','uploaded_by',
                         'extract_locked_by','extract_locked_at','extract_lock_touched_at',
                         'access_token','token_expires_at','carrier_payload','signature','signature_uuid',
                         'pod_signature','pod_photo_url','search_vector'];
begin
  -- Which order.
  case v_how
    when 'quotation'       then v_qid := (v_row->>'quotation_id')::int;
    when 'item'            then v_qid := (v_row->>'quotation_id')::int; v_item := (v_row->>'quotation_item_id')::int;
    when 'vendor'          then v_qid := (v_row->>'quotation_id')::int;
    when 'vendor_item'     then v_item := (v_row->>'quotation_item_id')::int;
    when 'confirmed_order' then v_qid := (v_row->>'quotation_id')::int;
    when 'confirmed_item'  then v_item := (v_row->>'quotation_item_id')::int;
    when 'by_confirmed_order' then v_co := (v_row->>'confirmed_order_id')::int;
    when 'by_confirmed_item'  then v_ci := (v_row->>'confirmed_item_id')::int;
    when 'by_item'         then v_item := (v_row->>'quotation_item_id')::int;
    when 'note' then
      case v_row->>'note_type'
        when 'quotations'      then v_qid := (v_row->>'type_id')::int;
        when 'quotation_items' then v_item := (v_row->>'type_id')::int;
        when 'confirmed_items' then v_ci := (v_row->>'type_id')::int;
        else return coalesce(new, old);
      end case;
    else return coalesce(new, old);
  end case;
  if v_ci is not null and v_item is null then
    select ci.quotation_item_id into v_item from qvm_new_apps.confirmed_items ci where ci.confirmed_item_id = v_ci;
  end if;
  if v_item is not null and v_qid is null then
    select qi.quotation_id into v_qid from qvm_new_apps.quotation_items qi where qi.quotation_item_id = v_item;
  end if;
  if v_co is not null and v_qid is null then
    select co.quotation_id into v_qid from qvm_new_apps.confirmed_orders co where co.confirmed_order_id = v_co;
  end if;
  if v_qid is null then return coalesce(new, old); end if;

  -- What changed.
  if tg_op = 'UPDATE' then
    for v_key in select jsonb_object_keys(v_new) loop
      if v_key = any(v_skip) then continue; end if;
      if v_new->v_key is distinct from v_old->v_key then
        v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_object('old', v_old->v_key, 'new', v_new->v_key));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    for v_key in select jsonb_object_keys(v_new) loop
      if v_key = any(v_skip) or v_new->v_key is null or v_new->v_key = 'null'::jsonb then continue; end if;
      v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_object('new', v_new->v_key));
    end loop;
  else
    for v_key in select jsonb_object_keys(v_old) loop
      if v_key = any(v_skip) or v_old->v_key is null or v_old->v_key = 'null'::jsonb then continue; end if;
      v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_object('old', v_old->v_key));
    end loop;
  end if;

  -- Who did it: the signed-in user; failing that, whichever «by» column the row carries.
  v_actor := coalesce(auth.uid(),
                      nullif(v_new->>'updated_by', '')::uuid,
                      nullif(v_new->>'status_changed_by', '')::uuid,
                      nullif(v_new->>'changed_by', '')::uuid,
                      nullif(v_new->>'created_by', '')::uuid,
                      nullif(v_new->>'uploaded_by', '')::uuid,
                      nullif(v_new->>'user_id', '')::uuid);

  insert into qvm_new_apps.quotation_audit_log (quotation_id, quotation_item_id, source_table, source_id, action, changes, actor)
  values (v_qid, v_item, tg_table_name,
          coalesce((v_row->>'quotation_item_id')::bigint, (v_row->>'confirmed_item_id')::bigint, (v_row->>'purchase_item_id')::bigint,
                   (v_row->>'purchase_order_id')::bigint, (v_row->>'confirmed_order_id')::bigint, (v_row->>'quotation_vendor_id')::bigint,
                   (v_row->>'cost_id')::bigint, (v_row->>'return_log_id')::bigint, (v_row->>'returned_issue_id')::bigint,
                   (v_row->>'return_item_id')::bigint, (v_row->>'return_id')::bigint, (v_row->>'delivery_item_id')::bigint,
                   (v_row->>'delivery_id')::bigint, (v_row->>'shipment_id')::bigint, (v_row->>'cancellation_id')::bigint,
                   (v_row->>'note_id')::bigint, (v_row->>'quotation_id')::bigint),
          lower(tg_op), v_changes, v_actor);
  return coalesce(new, old);
exception when others then
  -- The log never stops the order.
  return coalesce(new, old);
end $function$;

-- Every table an order lives in.
do $$
declare
  t record;
begin
  for t in select * from (values
      ('quotations',                   'quotation'),
      ('quotation_items',              'item'),
      ('quotation_vendors',            'vendor'),
      ('quotation_vendor_items',       'vendor_item'),
      ('quotation_vendor_item_alternatives', 'by_item'),
      ('confirmed_orders',             'confirmed_order'),
      ('confirmed_items',              'confirmed_item'),
      ('purchase_orders',              'by_confirmed_order'),
      ('purchase_items',               'by_confirmed_item'),
      ('deliveries',                   'by_confirmed_order'),
      ('delivery_items',               'by_confirmed_item'),
      ('delivery_notes',               'by_confirmed_item'),
      ('shipments',                    'by_confirmed_order'),
      ('returns',                      'by_confirmed_order'),
      ('return_items',                 'by_confirmed_item'),
      ('return_notes',                 'by_confirmed_item'),
      ('confirmed_item_return_log',    'by_confirmed_item'),
      ('returned_issues',              'by_confirmed_item'),
      ('quotation_item_cancellations', 'by_item'),
      ('notes',                        'note')
    ) as x(tbl, how)
  loop
    if to_regclass('qvm_new_apps.' || t.tbl) is null then continue; end if;
    execute format('drop trigger if exists trg_audit_quotation_change on qvm_new_apps.%I', t.tbl);
    execute format('create trigger trg_audit_quotation_change after insert or update or delete on qvm_new_apps.%I for each row execute function qvm_new_apps.audit_quotation_change(%L)', t.tbl, t.how);
  end loop;
end $$;

-- ───────────────────────── reading the story ─────────────────────────

-- A value in words: a status id becomes its name, a vendor id its vendor, a user id its user.
create or replace function qvm_new_apps.audit_describe(p_col text, p_val jsonb)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_txt text; v_out text;
begin
  if p_val is null or p_val = 'null'::jsonb then return null; end if;
  v_txt := case when jsonb_typeof(p_val) = 'string' then p_val #>> '{}' else p_val::text end;
  if p_col in ('item_status','vendor_item_status','vendor_status','status_before_request','order_type','delivery_type',
               'brand_class','final_brand_class','alternative_brand_class','available_brand_class','main_brand','available_brand_id',
               'cancellation_reason','client_return_reason','return_reason','return_type','reason_id','part_category',
               'payment_account','status','status_id','trigger_status','recipient_role_id','user_role','main_supplier')
     and v_txt ~ '^[0-9]+$' then
    select ld.list_data into v_out from qvm_new_apps.list_data ld where ld.list_data_id = v_txt::int;
    if v_out is not null then return v_out || ' (#' || v_txt || ')'; end if;
  end if;
  if p_col in ('vendor_id') and v_txt ~ '^[0-9]+$' then
    select v.vendor_name into v_out from qvm_new_apps.vendors v where v.vendor_id = v_txt::int;
    if v_out is not null then return v_out; end if;
  end if;
  if p_col in ('vendor_branch_id','pickup_vendor_branch_id') and v_txt ~ '^[0-9]+$' then
    select vb.branch_name into v_out from qvm_new_apps.vendor_branches vb where vb.vendor_branch_id = v_txt::bigint;
    if v_out is not null then return v_out; end if;
  end if;
  if p_col in ('cost_id','selected_cost_id','customer_price_cost_id','chosen_alternative_id','rebought_cost_id') and v_txt ~ '^[0-9]+$' then
    select v.vendor_name || case when qvi.cost is not null then ' @ ' || qvi.cost::text else '' end into v_out
      from qvm_new_apps.quotation_vendor_items qvi join qvm_new_apps.vendors v on v.vendor_id = qvi.vendor_id
     where qvi.cost_id = v_txt::int;
    if v_out is not null then return v_out || ' (#' || v_txt || ')'; end if;
  end if;
  if p_col in ('customer_id','client_branch_id') and v_txt ~ '^[0-9]+$' then
    select coalesce(vb.name, cb.branch_name) into v_out from qvm_new_apps.client_branches cb
      left join qvm_new_apps.v_client_branches vb on vb.customer_id = cb.customer_id where cb.customer_id = v_txt::int;
    if v_out is not null then return v_out; end if;
  end if;
  if p_col in ('company_id','client_id') and v_txt ~ '^[0-9]+$' then
    select coalesce(vc.name, ld.list_data) into v_out from qvm_new_apps.list_data ld
      left join qvm_new_apps.v_client_companies vc on vc.company_id = ld.list_data_id where ld.list_data_id = v_txt::int;
    if v_out is not null then return v_out; end if;
  end if;
  if p_col = 'end_customer_id' and v_txt ~ '^[0-9]+$' then
    select v.name into v_out from qvm_new_apps.v_end_customers v where v.end_customer_id = v_txt::bigint;
    if v_out is not null then return v_out; end if;
  end if;
  if v_txt ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select ud.user_name into v_out from qvm_new_apps.user_data ud where ud.user_id = v_txt::uuid;
    if v_out is not null then return v_out; end if;
  end if;
  return v_txt;
exception when others then
  return v_txt;
end $function$;

create or replace function qvm_new_apps.quotation_activity(p_order_number text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_q record;
  v_scope integer[];
  v_start timestamptz := qvm_new_apps.quotation_audit_started_at();
  v_events jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select q.*, (select min(qi.customer_id) from qvm_new_apps.quotation_items qi where qi.quotation_id = q.quotation_id) as branch_id
    into v_q
    from qvm_new_apps.quotations q
   where q.order_number = btrim(p_order_number)
   order by q.quotation_id desc limit 1;
  if v_q.quotation_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  -- Internal users see every order they can reach; anyone else only an order of their own branches.
  v_scope := qvm_new_apps.effective_branch_ids(v_uid);
  if v_scope is not null and not (v_q.branch_id = any(v_scope)) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  with
  people as (
    select ud.user_id, ud.user_name, ld.list_data as role_name
      from qvm_new_apps.user_data ud left join qvm_new_apps.list_data ld on ld.list_data_id = ud.user_role
  ),
  -- Since the log began: everything, as written.
  audited as (
    select a.created_at as at, a.actor, a.quotation_item_id, a.source_table, a.action, a.changes, a.source_id, 'audit' as origin
      from qvm_new_apps.quotation_audit_log a
     where a.quotation_id = v_q.quotation_id
  ),
  -- Before it began: the logs that existed, shaped the same way.
  legacy as (
    select v_q.created_at as at, v_q.service_advisor as actor, null::int as quotation_item_id, 'quotations' as source_table, 'insert' as action,
           jsonb_build_object('order_number', jsonb_build_object('new', to_jsonb(v_q.order_number))) as changes, v_q.quotation_id::bigint as source_id, 'legacy' as origin
     where v_q.created_at < v_start
    union all
    -- The line as it was raised: the part number before its first recorded change, when there was one.
    select qi.created_at, qi.created_by, qi.quotation_item_id, 'quotation_items', 'insert',
           jsonb_build_object('part_number', jsonb_build_object('new', to_jsonb(coalesce(
                                (select c0.old_part_number from qvm_new_apps.quotation_item_part_number_changes c0
                                  where c0.quotation_item_id = qi.quotation_item_id order by c0.changed_at limit 1), qi.part_number))),
                              'part_description', jsonb_build_object('new', to_jsonb(qi.part_description)),
                              'quantity', jsonb_build_object('new', to_jsonb(qi.quantity))), qi.quotation_item_id, 'legacy'
      from qvm_new_apps.quotation_items qi where qi.quotation_id = v_q.quotation_id and qi.created_at < v_start
    union all
    select sl.created_at, coalesce(sl.status_changed_by, sl.created_by), sl.quotation_item_id, 'quotation_items', 'update',
           jsonb_build_object('item_status', jsonb_build_object('new', to_jsonb(sl.item_status))), sl.status_log_id, 'legacy'
      from qvm_new_apps.status_logs sl join qvm_new_apps.quotation_items qi on qi.quotation_item_id = sl.quotation_item_id
     where qi.quotation_id = v_q.quotation_id and sl.created_at < v_start
    union all
    select c.changed_at, c.changed_by, c.quotation_item_id::int, 'quotation_items', 'update',
           jsonb_build_object('part_number', jsonb_build_object('old', to_jsonb(c.old_part_number), 'new', to_jsonb(c.new_part_number))), c.change_id, 'legacy'
      from qvm_new_apps.quotation_item_part_number_changes c join qvm_new_apps.quotation_items qi on qi.quotation_item_id = c.quotation_item_id
     where qi.quotation_id = v_q.quotation_id and c.changed_at < v_start
    union all
    select cl.created_at, cl.created_by, qvi.quotation_item_id, 'quotation_vendor_items', 'update',
           jsonb_build_object('cost', jsonb_build_object('new', to_jsonb(cl.cost)), 'vendor_id', jsonb_build_object('new', to_jsonb(qvi.vendor_id)))
             || case when cl.before_discount is not null then jsonb_build_object('agency_price', jsonb_build_object('new', to_jsonb(cl.before_discount))) else '{}'::jsonb end
             || case when cl.pricing_source is not null then jsonb_build_object('price_source', jsonb_build_object('new', to_jsonb(cl.pricing_source))) else '{}'::jsonb end,
           cl.cost_log_id, 'legacy'
      from qvm_new_apps.cost_logs cl join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = cl.cost_id
      join qvm_new_apps.quotation_items qi on qi.quotation_item_id = qvi.quotation_item_id
     where qi.quotation_id = v_q.quotation_id and cl.created_at < v_start
    union all
    select pl.created_at, coalesce(pl.updated_by, pl.created_by), pl.quotation_item_id, 'quotation_items', 'update',
           jsonb_build_object('price_before_vat', jsonb_build_object('new', to_jsonb(pl.price)))
             || case when pl.pricing_source is not null then jsonb_build_object('pricing_source', jsonb_build_object('new', to_jsonb(pl.pricing_source))) else '{}'::jsonb end,
           pl.id, 'legacy'
      from qvm_new_apps.pricing_logs pl join qvm_new_apps.quotation_items qi on qi.quotation_item_id = pl.quotation_item_id
     where qi.quotation_id = v_q.quotation_id and pl.created_at < v_start
    union all
    select al.created_at, al.actor_user_id, al.quotation_item_id::int, coalesce(al.source_table, 'activity_log'), al.action,
           jsonb_build_object('summary', jsonb_build_object('new', to_jsonb(al.summary))), al.id, 'legacy'
      from qvm_new_apps.activity_log al
     where al.created_at < v_start
       and ((al.record_type in ('quotation', 'quotations') and al.record_id = v_q.quotation_id)
         or al.quotation_item_id in (select qi.quotation_item_id from qvm_new_apps.quotation_items qi where qi.quotation_id = v_q.quotation_id))
       and al.action not in ('status_change', 'price_added', 'price_edited')
    union all
    select co.created_at, null, null, 'confirmed_orders', 'insert', jsonb_build_object('client_po', jsonb_build_object('new', to_jsonb(co.client_po))), co.confirmed_order_id, 'legacy'
      from qvm_new_apps.confirmed_orders co where co.quotation_id = v_q.quotation_id and co.created_at < v_start
    union all
    select po.created_at, coalesce(po.created_by, po.uploaded_by), null, 'purchase_orders', 'insert',
           jsonb_build_object('vendor_id', jsonb_build_object('new', to_jsonb(po.vendor_id))), po.purchase_order_id, 'legacy'
      from qvm_new_apps.purchase_orders po join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = po.confirmed_order_id
     where co.quotation_id = v_q.quotation_id and po.created_at < v_start
    union all
    select dn.created_at, null, ci.quotation_item_id, 'delivery_notes', 'insert',
           jsonb_build_object('approved_quantity', jsonb_build_object('new', to_jsonb(dn.approved_quantity)), 'signed_by', jsonb_build_object('new', to_jsonb(dn.signed_by))), dn.confirmed_item_id, 'legacy'
      from qvm_new_apps.delivery_notes dn join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = dn.confirmed_item_id
      join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = ci.confirmed_order_id
     where co.quotation_id = v_q.quotation_id and dn.created_at < v_start
    union all
    select rl.approved_at, rl.approved_by, ci.quotation_item_id, 'confirmed_item_return_log', 'insert',
           jsonb_build_object('returned_qty', jsonb_build_object('new', to_jsonb(rl.returned_qty)), 'return_reason', jsonb_build_object('new', to_jsonb(rl.return_reason))), rl.return_log_id, 'legacy'
      from qvm_new_apps.confirmed_item_return_log rl join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = rl.confirmed_item_id
      join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = ci.confirmed_order_id
     where co.quotation_id = v_q.quotation_id and rl.approved_at < v_start
    union all
    select c.created_at, c.created_by, c.quotation_item_id, 'quotation_item_cancellations', 'insert',
           jsonb_build_object('qty', jsonb_build_object('new', to_jsonb(c.qty)), 'reason_id', jsonb_build_object('new', to_jsonb(c.reason_id)), 'note', jsonb_build_object('new', to_jsonb(c.note))), c.cancellation_id, 'legacy'
      from qvm_new_apps.quotation_item_cancellations c join qvm_new_apps.quotation_items qi on qi.quotation_item_id = c.quotation_item_id
     where qi.quotation_id = v_q.quotation_id and c.created_at < v_start
    union all
    select n.created_at, n.user_id, case when n.note_type = 'quotation_items' then n.type_id end, 'notes', 'insert',
           jsonb_build_object('note_description', jsonb_build_object('new', to_jsonb(n.note_description)), 'is_internal', jsonb_build_object('new', to_jsonb(n.is_internal))), n.note_id, 'legacy'
      from qvm_new_apps.notes n
     where n.created_at < v_start and coalesce(n.is_deleted, false) = false
       and ((n.note_type = 'quotations' and n.type_id = v_q.quotation_id)
         or (n.note_type = 'quotation_items' and n.type_id in (select qi.quotation_item_id from qvm_new_apps.quotation_items qi where qi.quotation_id = v_q.quotation_id)))
  ),
  all_events as (select * from audited union all select * from legacy),
  described as (
    select e.*,
           (select coalesce(jsonb_object_agg(k, jsonb_build_object(
                     'old', qvm_new_apps.audit_describe(k, e.changes->k->'old'),
                     'new', qvm_new_apps.audit_describe(k, e.changes->k->'new'))), '{}'::jsonb)
              from jsonb_object_keys(e.changes) k) as pretty
      from all_events e
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', d.at, 'actor', d.actor, 'actor_name', p.user_name, 'actor_role', p.role_name,
           'quotation_item_id', d.quotation_item_id,
           'part_number', qi.part_number, 'part_description', qi.part_description,
           'source_table', d.source_table, 'source_id', d.source_id, 'action', d.action,
           'changes', d.changes, 'pretty', d.pretty, 'origin', d.origin)
           order by d.at, d.source_table, d.source_id), '[]'::jsonb)
    into v_events
    from described d
    left join people p on p.user_id = d.actor
    left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = d.quotation_item_id;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'order', jsonb_build_object(
      'quotation_id', v_q.quotation_id, 'order_number', v_q.order_number, 'created_at', v_q.created_at,
      'created_by', qvm_new_apps.audit_describe('service_advisor', to_jsonb(v_q.service_advisor)),
      'account_manager', qvm_new_apps.audit_describe('account_manager', to_jsonb(v_q.account_manager)),
      'branch', qvm_new_apps.audit_describe('customer_id', to_jsonb(v_q.branch_id)),
      'company', qvm_new_apps.audit_describe('company_id', to_jsonb(v_q.company_id)),
      'customer', qvm_new_apps.audit_describe('end_customer_id', to_jsonb(v_q.end_customer_id)),
      'audit_started_at', v_start),
    'items', coalesce((select jsonb_agg(jsonb_build_object('quotation_item_id', qi.quotation_item_id, 'part_number', qi.part_number,
                                'part_description', qi.part_description, 'quantity', qi.quantity,
                                'item_status', qvm_new_apps.audit_describe('item_status', to_jsonb(qi.item_status)))
                                order by qi.quotation_item_id)
                         from qvm_new_apps.quotation_items qi where qi.quotation_id = v_q.quotation_id), '[]'::jsonb),
    'events', v_events));
end $function$;

create or replace function public.quotation_activity(p_order_number text)
 returns jsonb language sql stable security definer
as $function$ select qvm_new_apps.quotation_activity(p_order_number) $function$;
