-- Where a shipment is going, offered rather than typed.
--
-- shipment_create has always accepted `dropoff_address_id`, and fills the address line, the
-- contact and the phone from that record when the form sends none. But the form only ever offered
-- a free-text box, so the record was never referenced and whatever somebody typed won.
--
-- That is how a purchase came to say «riyadh» beside a branch that is in الثقبة: the text and the
-- record disagreed, and only the text was on screen. It also costs the dispatch its coordinates —
-- Mrsool is sent a point, and a line of prose has none, so a typed address cannot be delivered to
-- by a courier at all.
--
-- Locations are marked, because an address with no pin is one the carrier will refuse and the
-- person filling the form should know that before they pick it rather than after.

create or replace function qvm_new_apps.shipment_dropoff_addresses(p_company_id integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = qvm_new_apps, public
as $fn$
declare
  v_co integer := p_company_id;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if v_co is null then
    select ud.user_company into v_co
      from qvm_new_apps.user_data ud
     where ud.user_id = auth.uid() and ud.deleted_at is null
     limit 1;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
             'address_id', a.address_id,
             'label', a.label,
             'address_line', a.address_line,
             'city', a.city,
             'contact_name', a.contact_name,
             'contact_phone', a.contact_phone,
             'branch', b.name,
             'workshop', w.name,
             -- A courier needs a point. Said here so the form can mark the ones it cannot use.
             'has_point', a.geo_lat is not null and a.geo_lng is not null,
             'is_default', a.is_default)
           -- The default first, then located ones, then the rest: the order somebody would pick in.
           order by a.is_default desc,
                    (a.geo_lat is not null) desc,
                    coalesce(a.label, a.address_line))
      from qvm_new_apps.customer_addresses a
      join qvm_new_apps.v_client_branches b on b.customer_id = a.client_branch_id
      left join qvm_new_apps.v_client_workshops w on w.workshop_id = b.workshop_id
     where a.is_active
       and (v_co is null or b.company_id = v_co)
  ), '[]'::jsonb));
end
$fn$;

revoke all on function qvm_new_apps.shipment_dropoff_addresses(integer) from public;
grant execute on function qvm_new_apps.shipment_dropoff_addresses(integer) to authenticated;
