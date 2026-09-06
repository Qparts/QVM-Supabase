-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Update first, insert only when there is nothing to update.
--
-- The row for a number is written every thirty seconds for as long as the bridge runs,
-- and every one of those writes was an INSERT … ON CONFLICT that burned a sequence value
-- to do an update. Trying the UPDATE first means nextval is called once per number, when
-- it is first seen, and never again. The INSERT keeps its ON CONFLICT clause so two
-- bridges starting at the same moment still cannot both create the row.

create or replace function qvm_new_apps.wa_set_device_state(
  p_wa_account_id bigint,
  p_device_id text default null,
  p_state text default null,
  p_jid text default null,
  p_qr_png text default null,
  p_qr_ttl_seconds integer default null,
  p_error text default null,
  p_clear_pair_request boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v jsonb; v_unlinking boolean; v_phone text; v_hit boolean;
begin
  select (d.state = 'disconnecting' and p_state = 'disconnected') into v_unlinking
    from qvm_new_apps.wa_device_state d where d.wa_account_id = p_wa_account_id;
  v_unlinking := coalesce(v_unlinking, false);

  update qvm_new_apps.wa_device_state set
    device_id     = coalesce(p_device_id, wa_device_state.device_id),
    state         = coalesce(p_state, wa_device_state.state),
    jid           = case when v_unlinking then null
                         else coalesce(nullif(p_jid, ''), wa_device_state.jid) end,
    phone         = case when v_unlinking then null
                         else coalesce(split_part(nullif(p_jid, ''), '@', 1), wa_device_state.phone) end,
    qr_png        = case when p_qr_png is not null then p_qr_png
                         when p_state = 'connected' then null else wa_device_state.qr_png end,
    qr_expires_at = case when p_qr_png is not null
                           then now() + make_interval(secs => coalesce(p_qr_ttl_seconds, 30))
                         when p_state = 'connected' then null else wa_device_state.qr_expires_at end,
    connected_at  = case when p_state = 'connected' and wa_device_state.state <> 'connected' then now()
                         when p_state = 'connected' then wa_device_state.connected_at else null end,
    pair_requested_at = case when p_clear_pair_request or p_state = 'connected' then null
                             else wa_device_state.pair_requested_at end,
    last_error    = case when p_error is not null then left(p_error, 500) else wa_device_state.last_error end,
    last_seen_at  = now(),
    updated_at    = now()
  where wa_device_state.wa_account_id = p_wa_account_id;

  get diagnostics v_hit = row_count;

  if not v_hit then
    insert into qvm_new_apps.wa_device_state (wa_account_id, device_id, state, last_seen_at, updated_at)
    values (p_wa_account_id, p_device_id, coalesce(p_state,'new'), now(), now())
    on conflict (wa_account_id) where wa_account_id is not null do update set
      device_id    = coalesce(excluded.device_id, wa_device_state.device_id),
      state        = coalesce(excluded.state, wa_device_state.state),
      last_seen_at = now(),
      updated_at   = now();
  end if;

  select phone into v_phone from qvm_new_apps.wa_device_state where wa_account_id = p_wa_account_id;
  update qvm_new_apps.wa_accounts a
     set state      = case when p_state in ('connected','disconnected','pairing') then p_state else a.state end,
         phone_e164 = case when v_unlinking then a.phone_e164
                           else coalesce(nullif(v_phone,''), a.phone_e164) end,
         updated_at = now()
   where a.wa_account_id = p_wa_account_id;

  select to_jsonb(x) into v from (
    select wa_account_id, device_id, state, pair_requested_at
      from qvm_new_apps.wa_device_state where wa_account_id = p_wa_account_id) x;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end $function$;
