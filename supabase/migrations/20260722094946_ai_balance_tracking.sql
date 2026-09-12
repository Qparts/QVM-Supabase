-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Manually-entered balance snapshots; "remaining" is estimated from our tracked spend since the snapshot.
create table if not exists public.ai_balance_snapshots (
  id           bigint generated always as identity primary key,
  balance_usd  numeric(12,4) not null,
  note         text,
  set_by_uid   uuid,
  set_by_name  text,
  set_at       timestamptz not null default now()
);
create index if not exists ai_balance_snapshots_set_at_idx on public.ai_balance_snapshots (set_at desc);

create or replace function public.set_ai_balance(p_balance numeric, p_note text, p_user_name text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  insert into public.ai_balance_snapshots(balance_usd, note, set_by_uid, set_by_name)
  values (p_balance, nullif(p_note,''), auth.uid(), nullif(p_user_name,'')) returning id into v_id;
  return v_id;
end $$;
grant execute on function public.set_ai_balance(numeric,text,text) to authenticated;

create or replace function public.get_ai_balance()
returns json language plpgsql security definer set search_path = '' as $$
declare v_snap record; v_spent numeric;
begin
  if auth.uid() is null then return json_build_object('status','error','message','unauthorized','data',null); end if;
  select * into v_snap from public.ai_balance_snapshots order by set_at desc limit 1;
  if not found then
    return json_build_object('status','success','message','OK','data', json_build_object('has_balance', false));
  end if;
  select coalesce(round(sum(est_cost_usd),4),0) into v_spent
    from public.ai_usage_events where created_at >= v_snap.set_at;
  return json_build_object('status','success','message','OK','data', json_build_object(
    'has_balance', true,
    'balance_usd', v_snap.balance_usd,
    'set_at', v_snap.set_at,
    'set_by_name', v_snap.set_by_name,
    'note', v_snap.note,
    'system_spend_since', v_spent,
    'est_remaining', round(v_snap.balance_usd - v_spent, 4)
  ));
end $$;
grant execute on function public.get_ai_balance() to authenticated;
