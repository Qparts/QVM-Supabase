-- The overview speaks points, and carries the ceilings.
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
    select v_acct.company_id as pc, null::integer as pv
    where v_acct.company_id is not null
    union all
    select null, v_acct.vendor_id
    where v_acct.vendor_id is not null
    union all
    select null, vc.vendor_id
      from qvm_new_apps.vendor_companies vc
     where v_acct.company_id is not null and vc.company_id = v_acct.company_id
  ),
  spend as (
    select c.party_company_id pc, c.party_vendor_id pv, -sum(c.points) as month_points
      from qvm_new_apps.ai_credit_entries c
     where c.account_id = v_acct.account_id and c.kind = 'usage' and c.created_at >= v_month
     group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'company_id', p.pc,
           'vendor_id',  p.pv,
           'name', coalesce(nm.name, vn.vendor_name,
                            case when p.pc is not null then 'Company ' || p.pc
                                 else 'Vendor ' || p.pv end),
           'kind', case when p.pc is not null then 'company' else 'vendor' end,
           'is_self', (p.pc is not distinct from v_acct.company_id
                       and p.pv is not distinct from v_acct.vendor_id),
           'month_points', coalesce(s.month_points, 0),
           'share', case when coalesce(v_spend, 0) > 0
                         then round(coalesce(s.month_points, 0) / v_spend * 100, 1)
                         else null end,
           'is_enabled', coalesce(sw.is_enabled, true),
           'reason', sw.reason,
           -- Null is uncapped. 0 is «none at all», which is a different instruction.
           'monthly_limit', sw.monthly_point_limit,
           -- Sent even when there is no ceiling, so the screen can show «450 of ∞» and «450 of
           -- 100» with one piece of code instead of two.
           'limit_used', case when sw.monthly_point_limit is not null
                              then coalesce(s.month_points, 0) else null end,
           'over_limit', sw.monthly_point_limit is not null
                         and coalesce(s.month_points, 0) >= sw.monthly_point_limit)
         order by coalesce(s.month_points, 0) desc,
                  coalesce(nm.name, vn.vendor_name)), '[]'::jsonb)
    into v_parties
    from parties p
    left join spend s on s.pc is not distinct from p.pc and s.pv is not distinct from p.pv
    left join qvm_new_apps.ai_credit_party_policy sw
           on sw.account_id = v_acct.account_id
          and sw.party_company_id is not distinct from p.pc
          and sw.party_vendor_id  is not distinct from p.pv
    left join lateral (select d.name from qvm_new_apps.client_companies_descriptions d
                        where d.company_id = p.pc and d.name is not null
                        order by d.language_id limit 1) nm on true
    left join lateral (select v.vendor_name from qvm_new_apps.vendors v
                        where v.vendor_id = p.pv limit 1) vn on true;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'needs_owner', false,
    'account_id', v_acct.account_id,
    'company_id', v_co, 'vendor_id', v_vn,
    'balance', v_balance,
    'month_points', coalesce(v_spend, 0),
    -- The price is sent so the screen can say what a purchase will cost without knowing the
    -- formula. It is one number and it changes; a constant in the bundle would not.
    'point_price_sar', v_price,
    'is_enabled', coalesce(v_acct.is_enabled, true),
    'disabled_reason', v_acct.disabled_reason,
    'auto_topup_enabled', coalesce(v_acct.auto_topup_enabled, false),
    'auto_topup_threshold', v_acct.auto_topup_threshold,
    'auto_topup_points', v_acct.auto_topup_points,
    'auto_topup_last_at', v_acct.auto_topup_last_at,
    -- Surfaced rather than buried: an automatic purchase that has been failing for a week is
    -- the reason somebody's AI is about to stop, and nothing else on this page would say so.
    'auto_topup_failed_at', v_acct.auto_topup_failed_at,
    'wallet_id', v_wallet,
    'wallet_balance', coalesce((select sum(e.amount) from qvm_new_apps.wallet_entries e
                                 where e.wallet_id = v_wallet), 0),
    'can_manage', v_wallet is not null and qvm_new_apps.wallet_can_manage(v_wallet),
    'side', case when v_op then 'operator' else 'owner' end,
    'parties', v_parties));
end
$$;

create or replace function qvm_new_apps.ai_credit_entries_list(
  p_company_id integer default null,
  p_vendor_id  integer default null,
  p_limit      integer default 50,
  p_offset     integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op    boolean := qvm_new_apps.wallet_is_operator();
  v_co    integer := p_company_id;
  v_vn    integer := p_vendor_id;
  v_acct  bigint;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows  jsonb;
  v_total integer;
begin
  if not v_op then
    select ud.user_company, ud.user_vendor into v_co, v_vn
      from qvm_new_apps.user_data ud where ud.user_id = auth.uid() limit 1;
    if v_co is null and v_vn is null then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
  end if;

  v_acct := qvm_new_apps.ai_credit_account_of(v_co, v_vn, false);
  if v_acct is null then
    return jsonb_build_object('status', true, 'message', 'ok', 'data',
      jsonb_build_object('rows', '[]'::jsonb, 'total', 0));
  end if;

  select count(*) into v_total from qvm_new_apps.ai_credit_entries where account_id = v_acct;

  select coalesce(jsonb_agg(q.row order by q.ord), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'entry_id', c.entry_id, 'points', c.points, 'sar_amount', c.sar_amount,
               'kind', c.kind, 'description', c.description, 'created_at', c.created_at,
               'party_name', coalesce(nm.name, vn.vendor_name),
               'model', ev.model, 'route', ev.route,
               -- A purchase nobody clicked. Said as a flag rather than by leaving the actor
               -- blank, which reads as a name we failed to find.
               'automatic', c.kind = 'topup' and c.created_by is null,
               'actor', coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), u.email,
                                 ev.user_name)) as row,
             row_number() over (order by c.created_at desc, c.entry_id desc) as ord
        from qvm_new_apps.ai_credit_entries c
        left join public.ai_usage_events ev on ev.id = c.usage_event_id
        left join auth.users u on u.id = coalesce(c.created_by, ev.auth_uid)
        left join lateral (select d.name from qvm_new_apps.client_companies_descriptions d
                            where d.company_id = c.party_company_id and d.name is not null
                            order by d.language_id limit 1) nm on true
        left join lateral (select v.vendor_name from qvm_new_apps.vendors v
                            where v.vendor_id = c.party_vendor_id limit 1) vn on true
       where c.account_id = v_acct
       order by c.created_at desc, c.entry_id desc
       limit v_limit offset greatest(coalesce(p_offset, 0), 0)) q;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('rows', v_rows, 'total', v_total));
end
$$;
