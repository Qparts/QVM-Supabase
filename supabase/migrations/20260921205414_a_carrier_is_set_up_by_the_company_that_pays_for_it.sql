-- A carrier is set up by the company that pays for it.
--
-- The card said «Set up by Qparts operations» because credentials used to be platform-wide. They
-- are not any more, so a company can attach its own Mrsool account — which is the whole point of
-- putting the marketplace in each company's portal.
--
-- ── Which branches use it ──────────────────────────────────────────────────────────────────────
-- Enabling a carrier for the company is not the same as enabling it everywhere. A company with a
-- fleet in Riyadh and none in Dammam wants it on in one and off in the other, and that decision
-- belongs next to the branch rather than in somebody's head.
create table if not exists qvm_new_apps.carrier_branch_settings (
  company_id  integer not null references qvm_new_apps.client_companies(company_id) on delete cascade,
  carrier_id  integer not null references qvm_new_apps.list_data(list_data_id),
  branch_id   integer not null,
  enabled     boolean not null default false,
  -- Where the driver collects from at this branch. Free text because it is an instruction to a
  -- human driver, not an address the system routes on.
  pickup_note text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (company_id, carrier_id, branch_id)
);

alter table qvm_new_apps.carrier_branch_settings enable row level security;

comment on table qvm_new_apps.carrier_branch_settings is
  'Which of a company''s branches may dispatch with which carrier. Absent means off — a carrier '
  'switched on for the company does not become switched on for every branch it has.';

-- ── The settings screen's read ─────────────────────────────────────────────────────────────────
-- Connection state, branches, and what this carrier has already taken out of the wallet.
--
-- The token is NOT here, and there is no function anywhere that returns it to a browser. The
-- design's «إظهار» button is deliberately not built: a key the client can fetch is a key that has
-- left the server, whatever the UI does with it afterwards — which is the rule the carrier edge
-- function was already written to. Four characters are enough to tell two tokens apart, which is
-- the only thing a person needs the screen for.
--
-- NOTE: the branch id is corrected two migrations later — client_branches.list_data_id is not the
-- branch's key. See 20260921205801.
create or replace function qvm_new_apps.carrier_settings_get(
  p_carrier_key text,
  p_company_id  integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_op      boolean := qvm_new_apps.wallet_is_operator();
  v_co      integer := p_company_id;
  v_carrier integer;
  v_wallet  bigint;
  v_conn    jsonb;
  v_branches jsonb;
  v_trips   jsonb;
  v_balance numeric := 0;
begin
  if not v_op then
    select uc.company_id into v_co from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() limit 1;
  end if;
  if v_co is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select list_data_id into v_carrier from qvm_new_apps.list_data
   where lower(list_data) = lower(p_carrier_key) limit 1;
  if v_carrier is null then
    return jsonb_build_object('status', false, 'message', 'الناقل غير معروف', 'data', null);
  end if;

  v_wallet := qvm_new_apps.wallet_of(v_co, null, false);
  if v_wallet is not null then
    select coalesce(sum(amount), 0) into v_balance
      from qvm_new_apps.wallet_entries where wallet_id = v_wallet;
  end if;

  select jsonb_build_object(
           'attached', c.credential_id is not null,
           'own_account', c.company_id is not null,
           'environment', coalesce(c.environment, 'production'),
           'is_active', coalesce(c.is_active, false),
           'api_base_url', c.api_base_url,
           'token_hint', case when c.api_token is null then null
                              else '••••' || right(c.api_token, 4) end,
           'last_test_ok', c.last_test_ok,
           'last_test_at', c.last_test_at,
           'last_test_note', c.last_test_note,
           -- The webhook the carrier posts status updates to. The secret is what makes it
           -- unguessable, so the URL is only shown to somebody who may already read the settings.
           'webhook_url', case when c.webhook_secret is null then null
                               else 'https://exizrhlkxoqljiypzwyx.supabase.co/functions/v1/'
                                    || lower(p_carrier_key) || '?s=' || c.webhook_secret end)
    into v_conn
    from qvm_new_apps.carrier_credentials c
   where c.carrier_id = v_carrier
     and (c.company_id = v_co or c.company_id is null)
   order by c.company_id nulls last
   limit 1;

  -- Every branch of the company, with its switch. A branch that has never been touched shows as
  -- off rather than missing, because «not decided» and «off» look the same to a dispatcher and
  -- only one of them is a state somebody chose.
  select coalesce(jsonb_agg(jsonb_build_object(
           'branch_id', b.list_data_id, 'branch_name', b.branch_name,
           'enabled', coalesce(s.enabled, false),
           'pickup_note', s.pickup_note)
         order by b.branch_name), '[]'::jsonb)
    into v_branches
    from qvm_new_apps.client_branches b
    join qvm_new_apps.client_workshops w on w.workshop_id = b.workshop_id
    left join qvm_new_apps.carrier_branch_settings s
           on s.company_id = v_co and s.carrier_id = v_carrier and s.branch_id = b.list_data_id
   where w.company_id = v_co;

  -- What this carrier has actually taken out of the wallet. Read from the ledger rather than from
  -- the shipments, so the screen and the balance cannot disagree about what was charged.
  select coalesce(jsonb_agg(jsonb_build_object(
           'entry_id', e.entry_id, 'created_at', e.created_at,
           'description', e.description, 'reference', e.reference,
           'amount', e.amount, 'balance_after', e.balance_after)
         order by e.entry_id desc), '[]'::jsonb)
    into v_trips
    from (select * from qvm_new_apps.wallet_entries
           where wallet_id = v_wallet and source = 'carrier' and source_id = lower(p_carrier_key)
           order by entry_id desc limit 20) e;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'carrier_key', lower(p_carrier_key), 'carrier_id', v_carrier,
    'company_id', v_co, 'wallet_id', v_wallet, 'balance', v_balance,
    'connection', coalesce(v_conn, jsonb_build_object('attached', false, 'own_account', false,
                                                      'environment', 'production', 'is_active', false)),
    'branches', v_branches, 'trips', coalesce(v_trips, '[]'::jsonb),
    'can_manage', v_wallet is null or qvm_new_apps.wallet_can_manage(v_wallet),
    'side', case when v_op then 'operator' else 'owner' end));
end
$$;

revoke all on function qvm_new_apps.carrier_settings_get(text, integer) from public;
grant execute on function qvm_new_apps.carrier_settings_get(text, integer)
  to authenticated, service_role;
