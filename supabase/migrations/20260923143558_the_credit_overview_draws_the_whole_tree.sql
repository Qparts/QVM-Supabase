-- The credit overview draws the whole tree: the organisation, its workshops, its suppliers.
create or replace function qvm_new_apps.ai_credit_overview(
  p_company_id integer default null,
  p_vendor_id  integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op      boolean := qvm_new_apps.wallet_is_operator();
  v_co      integer := p_company_id;
  v_vn      integer := p_vendor_id;
  v_acct    record;
  v_wallet  bigint;
  v_balance numeric := 0;
  v_month   date := date_trunc('month', current_date)::date;
  v_spend   numeric := 0;
  v_parties jsonb;
  v_price   numeric := qvm_new_apps.ai_point_price();
begin
  if not v_op then
    select ud.user_company, ud.user_vendor into v_co, v_vn
      from qvm_new_apps.user_data ud where ud.user_id = auth.uid() limit 1;
    if v_co is null and v_vn is null then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
  end if;

  if v_co is null and v_vn is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data',
      jsonb_build_object('needs_owner', true, 'parties', '[]'::jsonb));
  end if;

  select a.* into v_acct from qvm_new_apps.ai_credit_accounts a
   where a.account_id = qvm_new_apps.ai_credit_account_of(v_co, v_vn, false);

  if v_acct.account_id is not null then
    v_balance := qvm_new_apps.ai_credit_balance(v_acct.account_id);
    select coalesce(-sum(c.points), 0) into v_spend
      from qvm_new_apps.ai_credit_entries c
     where c.account_id = v_acct.account_id and c.kind = 'usage'
       and c.created_at >= v_month;
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, v_vn, false);

  with parties as (
    -- The organisation itself.
    select 'company'::text as kind, v_acct.company_id as pc, null::integer as pv, null::bigint as pw
    where v_acct.company_id is not null
    union all
    select 'vendor', null, v_acct.vendor_id, null
    where v_acct.vendor_id is not null
    -- Its suppliers.
    union all
    select 'vendor', null, vc.vendor_id, null
      from qvm_new_apps.vendor_companies vc
     where v_acct.company_id is not null and vc.company_id = v_acct.company_id
    -- And its workshops, from the same link the Companies & Workshops page draws.
    union all
    select 'workshop', null, null, wc.workshop_id
      from qvm_new_apps.workshop_companies wc
     where v_acct.company_id is not null and wc.company_id = v_acct.company_id
  ),
  spend as (
    select c.party_company_id pc, c.party_vendor_id pv, c.party_workshop_id pw,
           -sum(c.points) as month_points
      from qvm_new_apps.ai_credit_entries c
     where c.account_id = v_acct.account_id and c.kind = 'usage' and c.created_at >= v_month
     group by 1, 2, 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', p.kind,
           'company_id', p.pc, 'vendor_id', p.pv, 'workshop_id', p.pw,
           'name', coalesce(nm.name, vn.vendor_name, ws.workshop_code,
                            case when p.pc is not null then 'Company ' || p.pc
                                 when p.pv is not null then 'Vendor ' || p.pv
                                 else 'Workshop ' || p.pw end),
           'is_self', (p.kind = 'company' and p.pc is not distinct from v_acct.company_id)
                      or (p.kind = 'vendor' and p.pv is not distinct from v_acct.vendor_id),
           'month_points', coalesce(s.month_points, 0),
           'share', case when coalesce(v_spend, 0) > 0
                         then round(coalesce(s.month_points, 0) / v_spend * 100, 1)
                         else null end,
           'is_enabled', coalesce(sw.is_enabled, true),
           'reason', sw.reason,
           'monthly_limit', sw.monthly_point_limit,
           'limit_used', case when sw.monthly_point_limit is not null
                              then coalesce(s.month_points, 0) else null end,
           'over_limit', sw.monthly_point_limit is not null
                         and coalesce(s.month_points, 0) >= sw.monthly_point_limit,
           -- A workshop with nobody assigned can never be charged, because the attribution runs
           -- through `user_workshops`. Said out loud so a permanent zero reads as «nobody is in
           -- it» rather than «it does not use the AI».
           'no_members', p.kind = 'workshop' and not exists (
             select 1 from qvm_new_apps.user_workshops uw where uw.workshop_id = p.pw))
         order by coalesce(s.month_points, 0) desc,
                  coalesce(nm.name, vn.vendor_name, ws.workshop_code)), '[]'::jsonb)
    into v_parties
    from parties p
    left join spend s
           on s.pc is not distinct from p.pc
          and s.pv is not distinct from p.pv
          and s.pw is not distinct from p.pw
    left join qvm_new_apps.ai_credit_party_policy sw
           on sw.account_id = v_acct.account_id
          and sw.party_company_id  is not distinct from p.pc
          and sw.party_vendor_id   is not distinct from p.pv
          and sw.party_workshop_id is not distinct from p.pw
    left join lateral (select d.name from qvm_new_apps.client_companies_descriptions d
                        where d.company_id = p.pc and d.name is not null
                        order by d.language_id limit 1) nm on true
    left join lateral (select v.vendor_name from qvm_new_apps.vendors v
                        where v.vendor_id = p.pv limit 1) vn on true
    left join lateral (select w.workshop_code from qvm_new_apps.client_workshops w
                        where w.workshop_id = p.pw limit 1) ws on true;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'needs_owner', false,
    'account_id', v_acct.account_id,
    'company_id', v_co, 'vendor_id', v_vn,
    'balance', v_balance,
    'month_points', coalesce(v_spend, 0),
    'point_price_sar', v_price,
    'is_enabled', coalesce(v_acct.is_enabled, true),
    'disabled_reason', v_acct.disabled_reason,
    'auto_topup_enabled', coalesce(v_acct.auto_topup_enabled, false),
    'auto_topup_threshold', v_acct.auto_topup_threshold,
    'auto_topup_points', v_acct.auto_topup_points,
    'auto_topup_last_at', v_acct.auto_topup_last_at,
    'auto_topup_failed_at', v_acct.auto_topup_failed_at,
    'wallet_id', v_wallet,
    'wallet_balance', coalesce((select sum(e.amount) from qvm_new_apps.wallet_entries e
                                 where e.wallet_id = v_wallet), 0),
    'can_manage', v_wallet is not null and qvm_new_apps.wallet_can_manage(v_wallet),
    'side', case when v_op then 'operator' else 'owner' end,
    'parties', v_parties));
end
$$;
