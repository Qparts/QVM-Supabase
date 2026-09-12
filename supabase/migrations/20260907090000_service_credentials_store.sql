-- Where a third-party key lives when it is not a deploy-time secret.
--
-- The Gemini key was in `VITE_GEMINI_API_KEY`, which Vite inlines into the browser bundle —
-- so it shipped to every visitor. Moving it to an Edge Function environment variable fixes
-- the exposure but puts it somewhere only a project admin can change, which is the wrong
-- place for something an operations person is expected to rotate.
--
-- So it lives here: written through a function, never read back by one, and reachable only
-- by the service role that the Edge Function runs as. Same shape as carrier_credentials,
-- for the same reason.
create table if not exists qvm_new_apps.service_credentials (
  service      text primary key,
  api_key      text,
  extra        jsonb,
  is_active    boolean not null default true,
  last_test_at timestamptz,
  last_test_ok boolean,
  last_test_note text,
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);

alter table qvm_new_apps.service_credentials enable row level security;

-- Writes only. There is deliberately no function that returns api_key: a key that any RPC
-- can hand back is a key that reaches a browser the moment somebody calls that RPC.
create or replace function qvm_new_apps.service_credential_save(p_service text, p_key text, p_extra jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_key text := nullif(btrim(coalesce(p_key, '')), '');
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if nullif(btrim(coalesce(p_service,'')), '') is null then
    return jsonb_build_object('status', false, 'message', 'اسم الخدمة مطلوب', 'data', null);
  end if;

  insert into qvm_new_apps.service_credentials (service, api_key, extra, updated_by)
  values (btrim(p_service), v_key, p_extra, auth.uid())
  on conflict (service) do update set
    -- Blank means «leave the key alone», not «erase it»: nobody can read it back to retype it.
    api_key    = coalesce(excluded.api_key, qvm_new_apps.service_credentials.api_key),
    extra      = coalesce(excluded.extra, qvm_new_apps.service_credentials.extra),
    updated_by = auth.uid(),
    updated_at = now();

  return jsonb_build_object('status', true, 'message', 'ok', 'data', null);
end
$function$;

-- What the settings screen may know: that a key exists, and how it behaved last time.
-- Never the key.
create or replace function qvm_new_apps.service_credential_status(p_service text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select jsonb_build_object(
           'service', s.service,
           'configured', s.api_key is not null,
           'is_active', s.is_active,
           'last_test_at', s.last_test_at,
           'last_test_ok', s.last_test_ok,
           'last_test_note', s.last_test_note,
           'updated_at', s.updated_at)
    into v
    from qvm_new_apps.service_credentials s where s.service = p_service;
  return jsonb_build_object('status', true, 'message', 'ok',
    'data', coalesce(v, jsonb_build_object('service', p_service, 'configured', false)));
end
$function$;

-- Written by the Edge Function after it has actually called the provider, so the screen can
-- say «worked at 14:32» rather than «a key is present», which is not the same claim.
create or replace function qvm_new_apps.service_credential_record_test(
  p_service text, p_ok boolean, p_note text)
returns void
language sql
security definer
set search_path to 'qvm_new_apps', 'public'
as $fn$
  update qvm_new_apps.service_credentials
     set last_test_at = now(), last_test_ok = p_ok, last_test_note = p_note
   where service = p_service;
$fn$;

revoke all on function qvm_new_apps.service_credential_save(text, text, jsonb) from public;
revoke all on function qvm_new_apps.service_credential_status(text) from public;
revoke all on function qvm_new_apps.service_credential_record_test(text, boolean, text) from public;
grant execute on function qvm_new_apps.service_credential_save(text, text, jsonb) to authenticated;
grant execute on function qvm_new_apps.service_credential_status(text) to authenticated;
grant execute on function qvm_new_apps.service_credential_record_test(text, boolean, text) to service_role;
