-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Creating a vendor from a conversation now goes through the Vendors module's own call.
--
-- It used to insert straight into `vendors` with a name and a phone number, which produced
-- something no other vendor in the database looks like: no vendor_type, no branch, and so no
-- preferred_branch_id — while every one of the 56 vendors created through the Vendors screen
-- has all three. It also skipped that screen's permission rule, so anyone who could answer a
-- WhatsApp message could create a supplier record.
--
-- Delegating to create_vendor_with_branches means there is one implementation of "a vendor
-- exists" rather than two that drift: same authorisation (admin / finance manager / pricing
-- supervisor / account manager), same required fields, same first-branch-becomes-preferred
-- rule, same default login created by the trigger on `vendors`.
--
-- Being a WhatsApp agent is still required as well — the two checks are about different
-- things: one is "may you touch this number's conversations", the other "may you create a
-- supplier".

-- Dropped rather than replaced: the argument list changed, and `create or replace` with a
-- different signature leaves both versions in place. PostgREST then picks between overloads
-- by the JSON keys it is handed, which is a coin toss nobody can read from the client.
drop function if exists qvm_new_apps.wa_create_vendor_from_contact(bigint, text);

create or replace function qvm_new_apps.wa_create_vendor_from_contact(
  p_wa_contact_id bigint,
  p_vendor_name text,
  p_vendor_type text,
  p_city text,
  p_vendor_type_id integer default null,
  p_email text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_phone text;
  v_name  text := nullif(btrim(p_vendor_name), '');
  v_type  text := nullif(btrim(p_vendor_type), '');
  v_city  text := nullif(btrim(p_city), '');
  v_email text := nullif(btrim(p_email), '');
  v_res   jsonb;
  v_vendor integer;
begin
  perform qvm_new_apps.wa_require(qvm_new_apps.wa_account_of_contact(p_wa_contact_id), 'agent');

  if v_name is null then
    return jsonb_build_object('status', false, 'message', 'vendor name is required', 'data', null);
  end if;
  if v_type is null then
    return jsonb_build_object('status', false, 'message', 'vendor type is required', 'data', null);
  end if;
  if v_city is null then
    return jsonb_build_object('status', false, 'message', 'city is required', 'data', null);
  end if;

  select phone_e164 into v_phone from qvm_new_apps.wa_contacts
   where wa_contact_id = p_wa_contact_id and chat_type = 'individual';
  if v_phone is null then
    return jsonb_build_object('status', false, 'message', 'contact not found', 'data', null);
  end if;

  begin
    -- auth.uid(), not a service identity: the Vendors module checks the *caller's* role, and
    -- passing anything else here would hand a permission away rather than honour it.
    v_res := public.create_vendor_with_branches(
      auth.uid(),
      jsonb_build_object(
        'vendor_name', v_name,
        'vendor_type', v_type,
        'vendor_type_id', p_vendor_type_id,
        'receives_quotations', true,
        'email', v_email,
        'phone_numbers', jsonb_build_array(v_phone)),
      -- One branch, because the module requires at least one and this is all a conversation
      -- can tell us. Its notification defaults are left exactly as the Vendors screen sets
      -- them: turning WhatsApp notices on here would start sending on a record nobody has
      -- finished filling in.
      jsonb_build_array(jsonb_build_object(
        'branch_name', v_name,
        'city', v_city,
        'phone', v_phone,
        'is_active', true))
    );
  exception when others then
    -- 'Unauthorized' and the missing-field messages arrive here as exceptions; the inbox
    -- shows them as text, so they must not surface as a raw Postgres error.
    return jsonb_build_object('status', false, 'message', sqlerrm, 'data', null);
  end;

  v_vendor := nullif(v_res->>'vendor_id','')::integer;
  if v_vendor is null then
    return jsonb_build_object('status', false,
      'message', coalesce(v_res->>'message', 'could not create the vendor'), 'data', null);
  end if;

  update qvm_new_apps.wa_contacts
     set vendor_id = v_vendor, display_name = coalesce(display_name, v_name),
         linked_by = auth.uid(), linked_at = now()
   where wa_contact_id = p_wa_contact_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object(
      'vendor_id', v_vendor,
      'vendor_name', v_name,
      'branch_ids', coalesce(v_res->'branch_ids', '[]'::jsonb),
      -- Reported so the person is told the login exists rather than discovering it later.
      'login_created', coalesce((v_res->>'login_created')::boolean, false),
      'login_email', v_res->>'login_email'));
end $function$;

revoke execute on function qvm_new_apps.wa_create_vendor_from_contact(bigint, text, text, text, integer, text) from public;
grant execute on function qvm_new_apps.wa_create_vendor_from_contact(bigint, text, text, text, integer, text) to authenticated, anon;
