-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- S-5 — «تتبع الشحنة» has to be reachable from the boards, and those boards hold the order
-- *number* people actually say out loud, not the confirmed-order id. Resolving it here means
-- the button can be dropped anywhere without each caller learning the join.
do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.shipment_track(bigint,integer)'::regprocedure);
  v_old text;
begin
  v_old := 'CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_track(p_shipment_id bigint DEFAULT NULL::bigint, p_order_id integer DEFAULT NULL::integer)';
  if position(v_old in v_def) = 0 then raise exception 'signature not found'; end if;
  v_def := replace(v_def, v_old,
    'CREATE OR REPLACE FUNCTION qvm_new_apps.shipment_track(p_shipment_id bigint DEFAULT NULL::bigint, p_order_id integer DEFAULT NULL::integer, p_order_number text DEFAULT NULL::text)');

  v_old := '  if v_id is null and p_order_id is not null then';
  if position(v_old in v_def) = 0 then raise exception 'lookup block not found'; end if;
  v_def := replace(v_def, v_old,
'  -- The order number as it is printed on the note, which is what somebody has in front of
  -- them when they ask where the parts are.
  if v_id is null and nullif(btrim(coalesce(p_order_number, '''')), '''') is not null then
    select s.shipment_id into v_id
      from qvm_new_apps.shipments s
      join qvm_new_apps.confirmed_orders co on co.confirmed_order_id = s.confirmed_order_id
      join qvm_new_apps.quotations q on q.quotation_id = co.quotation_id
     where q.order_number = btrim(p_order_number)
     order by s.created_at desc limit 1;
  end if;

  if v_id is null and p_order_id is not null then');

  execute v_def;
end
$mig$;

revoke all on function qvm_new_apps.shipment_track(bigint, integer, text) from public;
grant execute on function qvm_new_apps.shipment_track(bigint, integer, text) to authenticated;

-- The old two-argument overload would still be resolvable by PostgREST on its key set and
-- would quietly answer without ever looking at the order number. One signature only.
drop function if exists qvm_new_apps.shipment_track(bigint, integer);

-- S-3 acceptance criterion: «disabling a delivery type removes it from the create-order
-- options». The RFQ form is filled in by customers too, so this is readable by any signed-in
-- user — it says which types are on offer and nothing else.
create or replace function qvm_new_apps.shipping_enabled_type_ids()
returns jsonb
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $fn$
  select coalesce(jsonb_agg(s.ship_type_id), '[]'::jsonb)
    from qvm_new_apps.shipping_settings s
   where s.ship_type_id is not null and s.is_enabled;
$fn$;

revoke all on function qvm_new_apps.shipping_enabled_type_ids() from public;
grant execute on function qvm_new_apps.shipping_enabled_type_ids() to authenticated;
