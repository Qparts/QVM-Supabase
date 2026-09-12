-- The edge function could not read the key it was told to use.
--
-- `service_credentials` was created without a GRANT, so although service_role bypasses RLS it
-- still had no SELECT privilege on the table — the REST read came back empty and the function
-- reported «no key is configured» while the settings screen, which asks through a SECURITY
-- DEFINER function, showed the key as present. Two answers to one question, from the same row.
--
-- Granting SELECT on the table would fix the symptom and widen the hole: anything running as
-- service_role could then read every credential we ever store. A function is narrower — it
-- returns one key, for one named service, to one role — and it is the same shape the rest of
-- this schema already uses.
create or replace function qvm_new_apps.service_credential_key(p_service text)
returns text
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $fn$
  select s.api_key
    from qvm_new_apps.service_credentials s
   where s.service = p_service and s.is_active;
$fn$;

revoke all on function qvm_new_apps.service_credential_key(text) from public, anon, authenticated;
grant execute on function qvm_new_apps.service_credential_key(text) to service_role;
