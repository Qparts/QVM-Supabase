-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- QNEW-124 S-1 / S-3 — the vocabulary before the tables.
--
-- Statuses are data, not an enum and not a CHECK: QQ2-14's rule, and the reason is that
-- Mrsool's own fourteen have to slot into the same dictionary as ours without a migration per
-- carrier. Both `lists` and `list_data` generate their ids ALWAYS, so nothing here picks a
-- number — the list is found by name and the rows hang off whatever id it was given.
do $mig$
declare
  v_list integer;
begin
  select list_id into v_list from qvm_new_apps.lists where list_name = 'shipment_status';
  if v_list is null then
    insert into qvm_new_apps.lists (list_name) values ('shipment_status') returning list_id into v_list;
  end if;

  insert into qvm_new_apps.list_data (list_id, list_data)
  select v_list, v.name
  from (values
    ('Draft'),
    ('Ready to Dispatch'),
    ('Dispatched'),
    ('Picked Up'),
    ('In Transit'),
    ('Out for Delivery'),
    ('Delivered'),
    ('Delivery Failed'),
    ('Returned'),
    ('Cancelled')
  ) as v(name)
  where not exists (
    select 1 from qvm_new_apps.list_data d
     where d.list_id = v_list and d.list_data = v.name);

  -- S-3 «تفعيل السائقين الداخليين»: a driver is a user with a role, not a new user type.
  -- Open Decision 2 recommends this, and it means a driver logs in, carries an identity in
  -- auth.uid(), and lands in every audit trail that already exists.
  insert into qvm_new_apps.list_data (list_id, list_data)
  select 16, 'Driver'
  where not exists (
    select 1 from qvm_new_apps.list_data d where d.list_id = 16 and d.list_data = 'Driver');
end
$mig$;

-- Application code asks for a status by name and never writes a number, so a carrier status
-- added to the list later is reachable the same way without touching anything.
create or replace function qvm_new_apps.shipment_status_id(p_name text)
returns integer
language sql
stable
set search_path to 'qvm_new_apps', 'public'
as $fn$
  select d.list_data_id
    from qvm_new_apps.list_data d
    join qvm_new_apps.lists l on l.list_id = d.list_id
   where l.list_name = 'shipment_status'
     and lower(d.list_data) = lower(p_name)
   limit 1;
$fn$;
