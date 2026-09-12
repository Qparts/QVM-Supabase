-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Group conversations were showing their id.
--
-- The inbound handler read the group's subject off the webhook — `chat_name` / `group_name`
-- — and the gateway sends neither. Every group message therefore arrived with no name, and
-- the list fell back to the only thing it had: «+120363420744972793», which is not a phone
-- number and tells nobody which group it is.
--
-- The subject is not on the message; it is on the group, and the gateway will list every
-- group the number belongs to with its name. So the bridge fetches that list and hands the
-- pairs here, the same way it hands over avatars.

create or replace function qvm_new_apps.wa_set_group_names(
  p_wa_account_id bigint,
  p_groups jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_updated int;
begin
  if p_wa_account_id is null or jsonb_typeof(p_groups) is distinct from 'array' then
    return jsonb_build_object('status', false, 'message', 'account and group list required', 'data', null);
  end if;

  with named as (
    select nullif(btrim(g->>'jid'), '')  as jid,
           nullif(btrim(g->>'name'), '') as name
      from jsonb_array_elements(p_groups) g
  ), touched as (
    update qvm_new_apps.wa_contacts c
       set wa_push_name = n.name,
           -- A name somebody typed here is kept; one that still matches what WhatsApp
           -- last said is theirs to change, so a renamed group follows its rename.
           display_name = case
             when c.display_name is null or c.display_name = c.wa_push_name then n.name
             else c.display_name end
      from named n
     where c.wa_account_id = p_wa_account_id
       and c.chat_type = 'group'
       and c.wa_jid = n.jid
       and n.name is not null
       and (c.wa_push_name is distinct from n.name or c.display_name is null)
    returning 1
  )
  select count(*) into v_updated from touched;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('updated', v_updated));
end $function$;

revoke execute on function qvm_new_apps.wa_set_group_names(bigint, jsonb) from public;
grant execute on function qvm_new_apps.wa_set_group_names(bigint, jsonb) to wa_bridge;
