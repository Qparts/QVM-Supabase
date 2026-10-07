-- Part descriptions can be corrected from the procurement dashboard, the Send-to-Vendor modal and
-- the pricing page, but only while the item is still Ready For Quotation (235) or Extract PN (236).
-- Every change of quotation_items.part_description — whichever path wrote it — is kept in
-- part_description_logs with the old and new text and the user who made it.

-- 1. The log -----------------------------------------------------------------------------------
create table if not exists qvm_new_apps.part_description_logs (
  log_id            bigserial primary key,
  quotation_item_id integer not null references qvm_new_apps.quotation_items(quotation_item_id) on delete cascade,
  quotation_id      integer,
  item_status       integer,
  old_description   text,
  new_description   text,
  changed_by        uuid,
  changed_at        timestamptz not null default now(),
  source            text
);
comment on table qvm_new_apps.part_description_logs is
  'One row per change of quotation_items.part_description: old/new text, the actor and the screen it came from.';
comment on column qvm_new_apps.part_description_logs.source is
  'Where the change was made: procurement_table, procurement_flow, send_vendor_modal, pricing_page, extract_pn or null for other writers.';

create index if not exists part_description_logs_item_idx on qvm_new_apps.part_description_logs (quotation_item_id, changed_at desc);
create index if not exists part_description_logs_quotation_idx on qvm_new_apps.part_description_logs (quotation_id);

alter table qvm_new_apps.part_description_logs enable row level security;
drop policy if exists part_description_logs_internal_read on qvm_new_apps.part_description_logs;
create policy part_description_logs_internal_read on qvm_new_apps.part_description_logs
  for select to authenticated using (qvm_new_apps.is_internal_user());
grant select on qvm_new_apps.part_description_logs to authenticated;
grant all on qvm_new_apps.part_description_logs to service_role;
grant usage, select on sequence qvm_new_apps.part_description_logs_log_id_seq to authenticated, service_role;

-- 2. The trigger: logs every description change, whoever wrote it ------------------------------
create or replace function qvm_new_apps.trg_log_part_description_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into qvm_new_apps.part_description_logs
    (quotation_item_id, quotation_id, item_status, old_description, new_description, changed_by, source)
  values
    (new.quotation_item_id, new.quotation_id, new.item_status, old.part_description, new.part_description,
     coalesce(auth.uid(), new.updated_by),
     nullif(current_setting('qvm.part_description_source', true), ''));
  return new;
end $$;

drop trigger if exists trg_log_part_description_change on qvm_new_apps.quotation_items;
create trigger trg_log_part_description_change
  after update of part_description on qvm_new_apps.quotation_items
  for each row
  when (new.part_description is distinct from old.part_description)
  execute function qvm_new_apps.trg_log_part_description_change();

-- 3. The gated edit -----------------------------------------------------------------------------
create or replace function qvm_new_apps.update_part_description(
  p_quotation_item_id integer,
  p_description text,
  p_source text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status integer;
  v_qid integer;
  v_old text;
  v_pn text;
  v_new text := btrim(coalesce(p_description, ''));
  v_log_id bigint;
begin
  if v_uid is null then
    return jsonb_build_object('status', false, 'message', 'Not authenticated');
  end if;
  if not qvm_new_apps.is_internal_user() then
    return jsonb_build_object('status', false, 'message', 'Access denied: Internal users only');
  end if;

  select qi.item_status, qi.quotation_id, coalesce(qi.part_description, ''), coalesce(qi.part_number, '')
    into v_status, v_qid, v_old, v_pn
  from qvm_new_apps.quotation_items qi
  where qi.quotation_item_id = p_quotation_item_id
  for update;
  if v_qid is null then
    return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id');
  end if;

  if v_status is distinct from 235 and v_status is distinct from 236 then
    return jsonb_build_object('status', false,
      'message', 'The part description can only be changed while the item is Ready For Quotation or Extract PN');
  end if;
  if v_new = '' and btrim(v_pn) = '' then
    return jsonb_build_object('status', false, 'message', 'Part Description and Part Number cannot both be empty');
  end if;
  if v_old = v_new then
    return jsonb_build_object('status', true, 'message', 'Unchanged',
      'data', jsonb_build_object('quotation_item_id', p_quotation_item_id, 'part_description', v_new));
  end if;

  perform set_config('qvm.part_description_source', coalesce(p_source, ''), true);
  update qvm_new_apps.quotation_items
     set part_description = v_new,
         updated_at = now()
   where quotation_item_id = p_quotation_item_id;
  perform set_config('qvm.part_description_source', '', true);

  select max(log_id) into v_log_id
  from qvm_new_apps.part_description_logs
  where quotation_item_id = p_quotation_item_id;

  -- the Extract PN module keeps its own event stream; a description amended there stays visible to it
  if v_status = 236 then
    begin
      perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'description_amended', v_old, v_new);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('status', true, 'message', 'OK',
    'data', jsonb_build_object(
      'quotation_item_id', p_quotation_item_id,
      'old_description', v_old,
      'part_description', v_new,
      'log_id', v_log_id));
end $$;

grant execute on function qvm_new_apps.update_part_description(integer, text, text) to authenticated, service_role;

-- 4. Reading the history ------------------------------------------------------------------------
create or replace function qvm_new_apps.list_part_description_logs(p_quotation_item_id integer)
returns table (
  log_id bigint,
  quotation_item_id integer,
  item_status integer,
  old_description text,
  new_description text,
  changed_by uuid,
  changed_by_name text,
  changed_at timestamptz,
  source text
)
language sql
stable
security definer
set search_path to ''
as $$
  select l.log_id, l.quotation_item_id, l.item_status, l.old_description, l.new_description,
         l.changed_by, ud.user_name, l.changed_at, l.source
  from qvm_new_apps.part_description_logs l
  left join qvm_new_apps.user_data ud on ud.user_id = l.changed_by
  where l.quotation_item_id = p_quotation_item_id
    and qvm_new_apps.is_internal_user()
  order by l.changed_at desc, l.log_id desc;
$$;

grant execute on function qvm_new_apps.list_part_description_logs(integer) to authenticated, service_role;

-- 5. The older inline editor honours the same gate for the description ------------------------
create or replace function public.update_quotation_item_inline(
  p_quotation_item_id integer,
  p_part_description text default null::text,
  p_part_number text default null::text,
  p_alternative_part_number text default null::text,
  p_part_category integer default null::integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public', 'pg_temp'
as $function$
declare
  v_uid uuid;
  v_user_type int;
  v_current_desc text;
  v_current_num text;
  v_current_status int;
  v_rows int;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized';
  end if;

  select user_type into v_user_type from user_data where user_id = v_uid;
  if v_user_type <> 185 then
    raise exception 'Access denied: Internal users only';
  end if;

  if p_part_category is not null then
    perform 1 from list_data where list_data_id = p_part_category;
    if not found then
      raise exception 'Invalid part_category (list_data_id %) provided', p_part_category;
    end if;
  end if;

  select part_description, part_number, item_status into v_current_desc, v_current_num, v_current_status
  from quotation_items where quotation_item_id = p_quotation_item_id;

  if not found then
    raise exception 'quotation_item_id % not found', p_quotation_item_id;
  end if;

  -- The description may only change while the item is Ready For Quotation or Extract PN
  if p_part_description is not null
     and p_part_description is distinct from v_current_desc
     and v_current_status not in (235, 236) then
    raise exception 'The part description can only be changed while the item is Ready For Quotation or Extract PN';
  end if;

  -- Validate: part description and part number cannot both be empty after update
  if coalesce(nullif(coalesce(p_part_description, v_current_desc), ''), '') = ''
     and coalesce(nullif(coalesce(p_part_number, v_current_num), ''), '') = '' then
    raise exception 'Part Description and Part Number cannot both be empty';
  end if;

  update quotation_items qi
  set
    part_description = coalesce(p_part_description, qi.part_description),
    part_number = coalesce(p_part_number, qi.part_number),
    alternative_part_number = coalesce(p_alternative_part_number, qi.alternative_part_number),
    part_category = coalesce(p_part_category, qi.part_category),
    item_status = CASE
      WHEN NULLIF(p_part_number, '') IS NOT NULL
           AND NULLIF(qi.part_number, '') IS NULL
           AND qi.item_status = 236
      THEN 235
      ELSE qi.item_status
    END
  where quotation_item_id = p_quotation_item_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'No changes applied';
  end if;

  -- Log the transition from Extract PN to Ready For Quotation if it happened
  IF NULLIF(p_part_number, '') IS NOT NULL THEN
    INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
    SELECT p_quotation_item_id, 235, v_uid, now()
    WHERE EXISTS (
      SELECT 1 FROM qvm_new_apps.quotation_items qi2
      WHERE qi2.quotation_item_id = p_quotation_item_id
        AND qi2.item_status = 235
        AND qi2.part_number IS NOT NULL
        AND trim(qi2.part_number) <> ''
    )
    ON CONFLICT DO NOTHING;
  END IF;

  return jsonb_build_object('status', 'success', 'message', 'quotation_item updated');
end;
$function$;

notify pgrst, 'reload schema';
