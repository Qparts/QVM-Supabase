-- «The vendors and workshops this company works with», written once.
--
-- The rule already existed — inside ai_credit_overview, spelled out in a UNION between
-- vendor_companies and workshop_companies. The wallet asks the same question, the shipment picker
-- asks it, and the integrations page asks it, and each was answering it its own way or not at all:
-- the shipment picker did not ask it, it asked «who is holding a part marked not_received», which
-- is a different question that happened to return a list of vendors.
--
-- Three spellings of one rule is how they come to disagree, and a picker that disagrees with the
-- wallet about who a company works with is worse than either being wrong on its own.
--
-- `kind` is what the row is, and exactly one of the three ids is set. A name never tells you
-- whether «abdullah» is a vendor or a workshop, and they are reached through different tables.

create or replace function qvm_new_apps.company_parties(p_company_id integer)
returns table (
  kind text,
  company_id integer,
  vendor_id integer,
  workshop_id bigint,
  name text,
  is_self boolean
)
language sql
stable
security definer
set search_path = qvm_new_apps, public
as $fn$
  with parties as (
    -- The company itself. It buys and it receives, so it is a party to its own shipments.
    select 'company'::text as kind, p_company_id as co, null::integer as vn, null::bigint as ws
    where p_company_id is not null
    union all
    -- Its suppliers, from the link the Vendors page draws.
    select 'vendor', null, vc.vendor_id, null
      from qvm_new_apps.vendor_companies vc
     where vc.company_id = p_company_id
    union all
    -- And its workshops, from the same link the Companies & Workshops page draws.
    select 'workshop', null, null, wc.workshop_id
      from qvm_new_apps.workshop_companies wc
     where wc.company_id = p_company_id
  )
  select p.kind,
         p.co::integer,
         p.vn::integer,
         p.ws::bigint,
         coalesce(
           co.name,
           v.vendor_name,
           w.name,
           -- Never a blank row. A party with no name is still a party, and «Workshop 11» is a
           -- thing you can pick; an empty line is not.
           case p.kind when 'company'  then 'Company '  || p.co
                       when 'vendor'   then 'Vendor '   || p.vn
                       else 'Workshop ' || p.ws end) as name,
         p.kind = 'company' as is_self
    from parties p
    left join qvm_new_apps.v_client_companies co on co.company_id = p.co
    left join qvm_new_apps.vendors v             on v.vendor_id   = p.vn
    left join qvm_new_apps.v_client_workshops w  on w.workshop_id = p.ws
   order by (p.kind = 'company') desc, 5;
$fn$;

revoke all on function qvm_new_apps.company_parties(integer) from public;
grant execute on function qvm_new_apps.company_parties(integer) to authenticated;
