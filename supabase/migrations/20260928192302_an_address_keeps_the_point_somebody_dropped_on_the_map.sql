-- A courier is dispatched to a point, and we were not keeping the point.
--
-- Mrsool takes a pickup coordinate and a dropoff coordinate. Nought of four customer addresses
-- have either, which reads like the map picker was never built — but it was: the address form has
-- one, and drops a pin, and resolves a place name from it. Two things then lose it.
--
-- 1. `customer_address_save` has no coordinate parameters at all. The customer-settings path
--    therefore discards whatever the picker produced, silently, on every save.
--
-- 2. `admin_save_branch_address` does take them, and writes them unconditionally:
--    `geo_lat = p_geo_lat`. So any save that does not carry a point — «make this the default
--    address», a contact-number correction — overwrites a good coordinate with NULL. The one
--    path that could record a point was also the path that erased it.
--
-- Both now treat a missing coordinate as «leave it alone» rather than «set it to nothing». You
-- cannot clear a pin by saving a form without one, which is right: a pin is cleared by moving it,
-- and an address that has been located does not become unlocated because somebody renamed it.

-- The argument list changes, and `create or replace` with a different list would leave the old
-- function beside the new one — callers would keep binding to whichever matches their arguments,
-- which here is the old one.
drop function if exists qvm_new_apps.customer_address_save(bigint, bigint, bigint, text, text, text, integer, text, text, boolean, boolean, boolean);

create or replace function qvm_new_apps.customer_address_save(
  p_customer_id bigint,
  p_address_id bigint default null,
  p_client_branch_id bigint default null,
  p_label text default null,
  p_address_line text default null,
  p_city text default null,
  p_region_id integer default null,
  p_contact_name text default null,
  p_contact_phone text default null,
  p_receives_orders boolean default true,
  p_receives_shipments boolean default true,
  p_is_default boolean default false,
  p_geo_lat numeric default null,
  p_geo_lng numeric default null
) returns jsonb
language plpgsql
security definer
set search_path = qvm_new_apps, public
as $fn$
declare
  v_id bigint;
begin
  -- Only one default per branch, and the new one wins.
  if p_is_default and p_client_branch_id is not null then
    update qvm_new_apps.customer_addresses
       set is_default = false, updated_at = now()
     where client_branch_id = p_client_branch_id and is_default
       and (p_address_id is null or address_id <> p_address_id);
  end if;

  if p_address_id is null then
    insert into qvm_new_apps.customer_addresses (
      customer_id, client_branch_id, label, address_line, city, region_id,
      contact_name, contact_phone, receives_orders, receives_shipments, is_default,
      geo_lat, geo_lng)
    values (p_customer_id, p_client_branch_id, p_label, btrim(p_address_line), p_city, p_region_id,
            p_contact_name, p_contact_phone, p_receives_orders, p_receives_shipments, p_is_default,
            p_geo_lat, p_geo_lng)
    returning address_id into v_id;
  else
    update qvm_new_apps.customer_addresses a
       set client_branch_id  = coalesce(p_client_branch_id, a.client_branch_id),
           label             = p_label,
           address_line      = btrim(p_address_line),
           city              = p_city,
           region_id         = p_region_id,
           contact_name      = p_contact_name,
           contact_phone     = p_contact_phone,
           receives_orders   = p_receives_orders,
           receives_shipments = p_receives_shipments,
           is_default        = p_is_default,
           -- Kept unless a new one is supplied. «Make this the default» must not un-locate it.
           geo_lat           = coalesce(p_geo_lat, a.geo_lat),
           geo_lng           = coalesce(p_geo_lng, a.geo_lng),
           updated_at        = now()
     where a.address_id = p_address_id
    returning a.address_id into v_id;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok',
                            'data', jsonb_build_object('address_id', v_id));
end
$fn$;

-- …and the admin path stops erasing what it is the only path able to record.
do $mig$
declare
  v_src text; v_new text; v_hits int;
  v_anchor text := E'        geo_lat = p_geo_lat, geo_lng = p_geo_lng,';
  v_repl   text := E'        -- coalesce, not assignment: a save that carries no point — renaming the\n        -- address, correcting a phone number, making it the default — was setting a good\n        -- coordinate back to NULL.\n        geo_lat = coalesce(p_geo_lat, geo_lat), geo_lng = coalesce(p_geo_lng, geo_lng),';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'admin_save_branch_address';
  if v_src is null then raise exception 'admin_save_branch_address is missing'; end if;

  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  if v_hits <> 1 then raise exception 'expected 1 geo assignment, found %', v_hits; end if;

  v_new := replace(v_src, v_anchor, v_repl);
  execute v_new;
end
$mig$;
