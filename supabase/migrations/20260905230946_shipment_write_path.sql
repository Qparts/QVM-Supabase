-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 §A — «the single write path».
--
-- The item statuses 22 / 213 / 23 already exist and already drive the delivered board. A
-- shipment must move them rather than shadow them, or the two will disagree and the older
-- one is the one the rest of the system reads. So every status change goes through here:
-- it writes the shipment, the log, and the items, in that order, once.
create or replace function qvm_new_apps.shipment_set_status(
  p_shipment_id bigint,
  p_status_name text,
  p_note text default null,
  p_actor uuid default null)
returns void
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_status integer := qvm_new_apps.shipment_status_id(p_status_name);
  v_actor uuid := coalesce(p_actor, auth.uid());
  v_ship record;
  v_item_status integer;
begin
  if v_status is null then
    raise exception 'unknown shipment status: %', p_status_name;
  end if;

  update qvm_new_apps.shipments s set
    status_id     = v_status,
    dispatched_at = case when p_status_name = 'Dispatched'  then coalesce(s.dispatched_at, now()) else s.dispatched_at end,
    picked_up_at  = case when p_status_name = 'Picked Up'   then coalesce(s.picked_up_at, now())  else s.picked_up_at end,
    delivered_at  = case when p_status_name = 'Delivered'   then coalesce(s.delivered_at, now())  else s.delivered_at end,
    failure_reason = case when p_status_name = 'Delivery Failed' then coalesce(p_note, s.failure_reason) else s.failure_reason end,
    updated_at    = now()
   where s.shipment_id = p_shipment_id
   returning * into v_ship;

  if v_ship is null then
    raise exception 'shipment % not found', p_shipment_id;
  end if;

  insert into qvm_new_apps.status_logs (shipment_id, item_status, status_changed_by, created_by)
  values (p_shipment_id, v_status, v_actor, v_actor);

  -- The items follow the shipment, not the other way round. Only for a delivery: a pickup is
  -- movement from the vendor to us and does not put anything in a customer's hands.
  if v_ship.delivery_id is not null then
    v_item_status := case p_status_name
      when 'Dispatched'       then 22   -- Out for Delivery
      when 'Out for Delivery' then 22
      when 'Delivered'        then 213  -- DN Sign Pending — the note still has to be signed
      else null
    end;

    if v_item_status is not null then
      update qvm_new_apps.confirmed_items ci set item_status = v_item_status
       where ci.confirmed_item_id in (
         select di.confirmed_item_id
           from qvm_new_apps.shipment_items si
           join qvm_new_apps.delivery_items di on di.delivery_item_id = si.delivery_item_id
          where si.shipment_id = p_shipment_id)
         and coalesce(ci.item_status, 0) <> v_item_status;

      insert into qvm_new_apps.status_logs (confirmed_item_id, item_status, status_changed_by, created_by)
      select di.confirmed_item_id, v_item_status, v_actor, v_actor
        from qvm_new_apps.shipment_items si
        join qvm_new_apps.delivery_items di on di.delivery_item_id = si.delivery_item_id
       where si.shipment_id = p_shipment_id;
    end if;
  end if;
end
$function$;

revoke all on function qvm_new_apps.shipment_set_status(bigint, text, text, uuid) from public;
grant execute on function qvm_new_apps.shipment_set_status(bigint, text, text, uuid) to authenticated, service_role;
revoke all on function qvm_new_apps.shipment_status_id(text) from public;
grant execute on function qvm_new_apps.shipment_status_id(text) to authenticated, service_role;
